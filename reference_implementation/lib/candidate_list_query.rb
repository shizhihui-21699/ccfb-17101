# frozen_string_literal: true

# Secure allowlist-based sorting/filtering reference implementation for a
# Ruby on Rails + Active Record recruiting application.
#
# The important boundary is:
#   HTTP parameter -> stable API field key -> Field policy/capability -> Arel
#
# HTTP input never becomes a SQL identifier. Values are cast and bound by
# Active Record.

require "date"
require "set"
require "active_record"

module CandidateList
  # Raised for unknown fields, unauthorized fields, bad operators and bad values.
  # The HTTP response should use the same generic message for every variant so
  # callers cannot enumerate which hidden fields exist.
  class InvalidQuery < StandardError
    attr_reader :reason

    # The externally visible message is always generic. `reason` can be logged
    # internally without telling an attacker which hidden field was recognized.
    def initialize(reason = :invalid_query)
      @reason = reason
      super("invalid list query")
    end
  end

  Field = Struct.new(
    :key,
    :column,
    :type,
    :roles,
    :operators,
    :aliases,
    :enum_values,
    :label,
    :sortable,
    :filterable,
    :default_filter_op,
    :max_string_length,
    keyword_init: true
  ) do
    def initialize(*)
      super
      self.key = key.to_sym
      self.column = (column || key).to_sym
      self.type = (type || :string).to_sym
      self.roles = Array(roles).map(&:to_sym).to_set
      self.operators = Array(operators).map(&:to_sym).to_set
      self.aliases = Array(aliases).map(&:to_s).to_set
      self.enum_values = Array(enum_values).map(&:to_s).to_set
      self.label = label || key.to_s.tr("_", " ").capitalize
      self.sortable = true if sortable.nil?
      self.filterable = true if filterable.nil?
      self.default_filter_op = (default_filter_op || :eq).to_sym
      self.max_string_length ||= 100
    end

    def permitted?(role, usage)
      capability = case usage
                   when :sort then sortable == true
                   when :filter then filterable == true
                   else false
                   end

      roles.include?(role.to_sym) && capability
    end
  end

  LegacyParam = Struct.new(:param, :field, :op, keyword_init: true) do
    def initialize(*)
      super
      self.param = param.to_s
      self.field = field.to_sym
      self.op = op.to_sym
    end
  end

  class Catalog
    def initialize(fields, legacy_params = [])
      @fields = {}
      @aliases = {}
      @legacy_params = {}

      fields.each { |field| register_field(field) }
      legacy_params.each { |mapping| @legacy_params[mapping.param] = mapping }
    end

    def resolve(name)
      return nil if name.nil?

      @aliases[name.to_s]
    end

    def field(key)
      @fields[key.to_sym]
    end

    def legacy_param(name)
      @legacy_params[name.to_s]
    end

    # Use this for BOTH sort and filter authorization. There is deliberately no
    # method that returns a field without checking role and usage.
    def permitted_field!(name, role, usage)
      key = resolve(name)
      record = key && @fields[key]

      unless record && record.permitted?(role, usage)
        # Production logs can retain the detailed reason; the API response must
        # stay generic.
        raise InvalidQuery, "field is unknown or not permitted for #{usage}"
      end

      record
    end

    # Powers GET /candidate_list/query_schema. New frontend code should render
    # controls from this response instead of concatenating database column names.
    def metadata(role)
      @fields.values.select { |field| field.roles.include?(role.to_sym) }.map do |field|
        {
          key: field.key,
          label: field.label,
          type: field.type,
          sortable: field.sortable,
          filterable: field.filterable,
          operators: field.operators.to_a,
          enum_values: field.enum_values.to_a
        }
      end
    end

    private

    def register_field(field)
      raise ArgumentError, "duplicate field #{field.key}" if @fields.key?(field.key)

      @fields[field.key] = field

      names = [field.key.to_s, field.column.to_s] + field.aliases.to_a
      names.each do |name|
        if @aliases.key?(name) && @aliases[name] != field.key
          raise ArgumentError, "alias #{name} is mapped more than once"
        end

        @aliases[name] = field.key
      end
    end
  end

  module TypeCaster
    module_function

    def cast(field, op, raw_value)
      case op
      when :in, :not_in
        values = case raw_value
                 when Array then raw_value
                 when String then raw_value.split(",")
                 else raise InvalidQuery, "expected a list"
                 end
        raise InvalidQuery, "expected a non-empty list" if values.empty?

        values.first(100).map { |value| scalar(field, value) }
      when :is_null, :not_null
        nil
      else
        scalar(field, raw_value)
      end
    end

    def scalar(field, raw_value)
      raise InvalidQuery, "value is required" if raw_value.nil?
      raise InvalidQuery, "nested values are not allowed" if raw_value.is_a?(Hash) || raw_value.is_a?(Array)

      case field.type
      when :string, :text
        value = raw_value.to_s
        raise InvalidQuery, "value is too long" if value.length > field.max_string_length

        value
      when :enum
        value = raw_value.to_s
        raise InvalidQuery, "invalid value" unless field.enum_values.include?(value)

        value
      when :integer
        strict_integer(raw_value)
      when :decimal
        strict_decimal(raw_value)
      when :boolean
        strict_boolean(raw_value)
      when :date
        Date.iso8601(raw_value.to_s)
      when :datetime
        Time.iso8601(raw_value.to_s)
      else
        raise InvalidQuery, "unsupported type"
      end
    rescue ArgumentError, TypeError
      raise InvalidQuery, "invalid value for #{field.type}"
    end

    def strict_integer(value)
      case value
      when Integer
        value
      when String
        Integer(value, 10)
      else
        raise InvalidQuery, "invalid integer"
      end
    end

    def strict_decimal(value)
      require "bigdecimal"

      case value
      when Numeric
        BigDecimal(value.to_s)
      when String
        BigDecimal(value)
      else
        raise InvalidQuery, "invalid decimal"
      end
    end

    def strict_boolean(value)
      if value == true || value == "true" || value == "1" || value == 1
        true
      elsif value == false || value == "false" || value == "0" || value == 0
        false
      else
        raise InvalidQuery, "invalid boolean"
      end
    end
  end

  class SortCompiler
    DIRECTIONS = {
      "asc" => :asc,
      "ascending" => :asc,
      "desc" => :desc,
      "descending" => :desc
    }.freeze

    MAX_SORT_FIELDS = 3

    def initialize(model, catalog, role, tie_breaker: :id)
      @model = model
      @catalog = catalog
      @role = role
      @tie_breaker = tie_breaker.to_sym
    end

    # Accepts:
    #   "applied_at"
    #   "-applied_at"
    #   { field: "applied_at", direction: "desc" }
    #   ["status", { field: "applied_at", direction: "desc" }]
    def compile(raw_sort, raw_direction = nil)
      entries = normalize_entries(raw_sort, raw_direction)
      raise InvalidQuery, "too many sort fields" if entries.length > MAX_SORT_FIELDS

      used_keys = Set.new
      orders = entries.map do |entry|
        field_name = entry.fetch(:field)
        field = @catalog.permitted_field!(field_name, @role, :sort)
        used_keys << field.key

        direction = parse_direction(entry[:direction]) || :asc
        column = @model.arel_table[field.column]
        column.public_send(direction)
      end

      # Unique tie-breaker keeps offset pagination stable. It is intentionally
      # a non-secret primary key, never a hidden business field.
      unless used_keys.include?(@tie_breaker)
        orders << @model.arel_table[@tie_breaker].desc
      end

      orders
    end

    def default_order
      [@model.arel_table[@tie_breaker].desc]
    end

    private

    def normalize_entries(raw_sort, raw_direction)
      case raw_sort
      when nil
        []
      when Array
        raw_sort.map { |item| normalize_one(item, raw_direction) }
      else
        [normalize_one(raw_sort, raw_direction)]
      end
    end

    def normalize_one(item, raw_direction)
      case item
      when Hash
        field = indifferent_fetch(item, "field")
        direction = indifferent_fetch(item, "direction") || raw_direction
        { field: field, direction: direction }
      when String, Symbol
        name = item.to_s
        inferred_direction = nil

        if name.start_with?("-")
          name = name[1..-1]
          inferred_direction = :desc
        elsif name.start_with?("+")
          name = name[1..-1]
          inferred_direction = :asc
        end

        { field: name, direction: raw_direction || inferred_direction }
      else
        raise InvalidQuery, "invalid sort"
      end
    end

    def parse_direction(value)
      return nil if value.nil?

      DIRECTIONS[value.to_s.downcase] || raise(InvalidQuery, "invalid direction")
    end

    def indifferent_fetch(hash, key)
      if hash.key?(key)
        hash[key]
      elsif hash.key?(key.to_sym)
        hash[key.to_sym]
      end
    end
  end

  class FilterCompiler
    OPERATOR_ALIASES = {
      eq: :eq,
      equal: :eq,
      not_eq: :not_eq,
      neq: :not_eq,
      in: :in,
      not_in: :not_in,
      gt: :gt,
      gte: :gte,
      gteq: :gte,
      lt: :lt,
      lte: :lte,
      lteq: :lte,
      contains: :contains,
      starts_with: :starts_with,
      ends_with: :ends_with,
      is_null: :is_null,
      not_null: :not_null
    }.freeze

    AREL_METHODS = {
      eq: :eq,
      not_eq: :not_eq,
      in: :in,
      not_in: :not_in,
      gt: :gt,
      gte: :gteq,
      lt: :lt,
      lte: :lteq
    }.freeze

    def initialize(model, catalog, role)
      @model = model
      @catalog = catalog
      @role = role
    end

    # Canonical input:
    #   [{ "field" => "status", "op" => "eq", "value" => "new" }]
    # or a single node/hash.
    def call(raw_filters)
      nodes = normalize_nodes(raw_filters)
      return nil if nodes.empty?

      predicates = nodes.map { |node| compile_node(node) }
      predicates.reduce { |combined, predicate| combined.and(predicate) }
    end

    private

    def normalize_nodes(raw)
      case raw
      when nil
        []
      when Array
        raw
      when Hash
        if raw.key?("field") || raw.key?(:field)
          [raw]
        else
          # Simple { status: "new" } form. Field authorization still applies.
          raw.map { |field, value| { field: field, op: :eq, value: value } }
        end
      else
        raise InvalidQuery, "invalid filters"
      end
    end

    def compile_node(node)
      raise InvalidQuery, "invalid filter" unless node.is_a?(Hash)

      field_name = fetch(node, "field")
      op_name = fetch(node, "op") || fetch(node, "operator") || "eq"
      raw_value = fetch(node, "value")

      field = @catalog.permitted_field!(field_name, @role, :filter)
      op = normalize_operator(op_name)

      raise InvalidQuery, "operator not allowed for field" unless field.operators.include?(op)

      value = TypeCaster.cast(field, op, raw_value)
      column = @model.arel_table[field.column]
      build_predicate(column, op, value)
    end

    def normalize_operator(name)
      key = name.to_s.gsub(/[-\s]/, "_").downcase.to_sym
      OPERATOR_ALIASES.fetch(key) { raise InvalidQuery, "unsupported operator" }
    end

    def build_predicate(column, op, value)
      case op
      when :contains
        column.matches("%#{escape_like(value)}%", "!")
      when :starts_with
        column.matches("#{escape_like(value)}%", "!")
      when :ends_with
        column.matches("%#{escape_like(value)}", "!")
      when :is_null
        column.eq(nil)
      when :not_null
        column.not_eq(nil)
      else
        method = AREL_METHODS[op]
        raise InvalidQuery, "unsupported operator" unless method

        column.public_send(method, value)
      end
    end

    def escape_like(value)
      value.to_s.gsub(/[!%_]/) { |char| "!#{char}" }
    end

    def fetch(hash, key)
      if hash.key?(key)
        hash[key]
      elsif hash.key?(key.to_sym)
        hash[key.to_sym]
      end
    end
  end

  # Translates old flat API parameters into canonical filter nodes.
  #
  # Compatibility means preserving DOCUMENTED old parameter names through this
  # mapping. It must NOT mean passing arbitrary old keys to SQL.
  class LegacyFilterTranslator
    def initialize(catalog)
      @catalog = catalog
    end

    def call(raw_params)
      return [] if raw_params.nil?

      unless raw_params.respond_to?(:each)
        raise InvalidQuery, "invalid legacy filters"
      end

      nodes = []
      raw_params.each do |raw_name, raw_value|
        name = raw_name.to_s
        next if blank_value?(raw_value)

        mapping = @catalog.legacy_param(name)

        if mapping
          nodes << { field: mapping.field, op: mapping.op, value: raw_value }
        elsif (key = @catalog.resolve(name))
          # Backwards compatibility for old callers that sent a raw column name.
          # The field's role/filter capability is checked again by the compiler.
          field = @catalog.field(key)
          nodes << { field: field.key, op: field.default_filter_op, value: raw_value }
        else
          raise InvalidQuery, "unknown legacy filter"
        end
      end

      nodes
    end

    private

    def blank_value?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end

  class Query
    def initialize(model:, scope:, catalog:, role:)
      @model = model
      # The caller supplies the tenant/company-scoped relation, for example
      # current_company.candidates. This class never starts from unscoped model.
      @scope = scope
      @catalog = catalog
      @role = role.to_sym
    end

    def call(sort: nil, direction: nil, filters: nil, legacy_filters: nil)
      relation = @scope.all

      canonical_filters = Array(filters)
      if legacy_filters
        canonical_filters += LegacyFilterTranslator.new(@catalog).call(legacy_filters)
      end

      predicate = FilterCompiler.new(@model, @catalog, @role).call(canonical_filters)
      relation = relation.where(predicate) if predicate

      compiler = SortCompiler.new(@model, @catalog, @role)
      orders = if sort.nil? && direction.nil?
                 compiler.default_order
               else
                 compiler.compile(sort, direction)
               end

      # reorder discards unsafe or hidden orders inherited from default scopes.
      relation.reorder(*orders)
    end
  end

  module Pagination
    module_function

    def offset(relation, page:, per_page:, max_per_page: 100)
      page = positive_integer(page, 1)
      per_page = [[positive_integer(per_page, 25), 1].max, max_per_page].min

      relation.limit(per_page).offset((page - 1) * per_page)
    end

    def positive_integer(value, default)
      case value
      when Integer
        value
      when String
        Integer(value, 10)
      else
        default
      end
    rescue ArgumentError, TypeError
      default
    end
  end

  def self.candidate_catalog
    roles_enterprise = %i[recruiter hiring_manager company_admin]

    Catalog.new(
      [
        Field.new(
          key: :id,
          type: :integer,
          roles: roles_enterprise,
          operators: %i[eq in]
        ),
        Field.new(
          key: :name,
          type: :string,
          roles: roles_enterprise,
          operators: %i[eq contains starts_with ends_with in],
          aliases: %w[full_name candidate_name candidates.name]
        ),
        Field.new(
          key: :email,
          type: :string,
          roles: roles_enterprise,
          operators: %i[eq contains starts_with],
          aliases: %w[candidates.email]
        ),
        Field.new(
          key: :status,
          type: :enum,
          enum_values: %w[new screening interview offer hired rejected],
          roles: roles_enterprise,
          operators: %i[eq not_eq in not_in],
          aliases: %w[candidate_status]
        ),
        Field.new(
          key: :applied_at,
          type: :datetime,
          roles: roles_enterprise,
          operators: %i[eq gt gte lt lte],
          aliases: %w[applied_date created_at candidates.applied_at]
        ),

        # Sensitive fields are absent from enterprise roles. They can still be
        # used by an authorized compensation/platform role through the same
        # registry and compiler.
        Field.new(
          key: :expected_salary,
          type: :integer,
          roles: %i[compensation_admin platform_admin],
          operators: %i[eq not_eq in gt gte lt lte],
          aliases: %w[salary expectedSalary expected_salary_min candidates.expected_salary]
        ),
        Field.new(
          key: :interviewing_elsewhere,
          type: :boolean,
          roles: %i[platform_admin],
          operators: %i[eq not_eq is_null not_null],
          aliases: %w[other_offers interviewingElsewhere competing_process candidates.interviewing_elsewhere]
        )
      ],
      [
        LegacyParam.new(param: "q", field: :name, op: :contains),
        LegacyParam.new(param: "keyword", field: :name, op: :contains),
        LegacyParam.new(param: "applied_from", field: :applied_at, op: :gte),
        LegacyParam.new(param: "applied_to", field: :applied_at, op: :lte),
        LegacyParam.new(param: "salary_min", field: :expected_salary, op: :gte),
        LegacyParam.new(param: "salary_max", field: :expected_salary, op: :lte)
      ]
    )
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/candidate_list_query"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false

ActiveRecord::Schema.define do
  create_table :candidates do |t|
    t.integer :company_id, null: false
    t.string :name
    t.string :email
    t.string :status
    t.datetime :applied_at
    t.integer :expected_salary
    t.boolean :interviewing_elsewhere
    t.timestamps
  end
end

class Candidate < ActiveRecord::Base; end

CATALOG = CandidateList.candidate_catalog

def create_candidate!(attrs)
  Candidate.create!(
    {
      company_id: 1,
      email: "#{attrs.fetch(:name).downcase.gsub(/\s+/, '_')}@example.test",
      status: "new",
      applied_at: Time.utc(2026, 1, 1),
      expected_salary: 0,
      interviewing_elsewhere: false
    }.merge(attrs)
  )
end

describe CandidateList::Query do
  before do
    Candidate.delete_all

    @alice = create_candidate!(
      name: "Alice Example", status: "interview", expected_salary: 300,
      interviewing_elsewhere: false, applied_at: Time.utc(2026, 1, 10)
    )
    @bob = create_candidate!(
      name: "Bob Hidden", status: "new", expected_salary: 100,
      interviewing_elsewhere: true, applied_at: Time.utc(2026, 1, 20)
    )
    @carol = create_candidate!(
      name: "Carol Smith", status: "interview", expected_salary: 200,
      interviewing_elsewhere: false, applied_at: Time.utc(2026, 1, 5)
    )
    @other_company = create_candidate!(
      company_id: 2, name: "Mallory Outside", expected_salary: 999
    )

    @scope = Candidate.where(company_id: 1)
  end

  def query(role: :recruiter, **options)
    CandidateList::Query.new(
      model: Candidate,
      scope: @scope,
      catalog: CATALOG,
      role: role
    ).call(**options)
  end

  def assert_invalid_query
    error = assert_raises(CandidateList::InvalidQuery) { yield }
    assert_equal "invalid list query", error.message
  end

  it "sorts by an allowed canonical field" do
    ids = query(sort: "name", direction: "asc").pluck(:id)

    assert_equal [@alice.id, @bob.id, @carol.id], ids
  end

  it "accepts minus-prefixed sort tokens and documented aliases" do
    ids = query(sort: "-applied_date").pluck(:id)

    assert_equal [@bob.id, @alice.id, @carol.id], ids
  end

  it "always appends a unique non-secret tie-breaker" do
    relation = query(sort: "status", direction: "asc")
    sql = relation.to_sql

    assert_includes sql, '"candidates"."status" ASC'
    assert_includes sql, '"candidates"."id" DESC'
    refute_includes sql, "expected_salary"
    refute_includes sql, "interviewing_elsewhere"
  end

  it "rejects hidden sort fields under every known legacy or frontend name" do
    %w[
      expected_salary
      salary
      expectedSalary
      candidates.expected_salary
      interviewing_elsewhere
      other_offers
      interviewingElsewhere
    ].each do |hidden_name|
      assert_invalid_query { query(sort: hidden_name) }
      assert_invalid_query { query(sort: "-#{hidden_name}") }
      assert_invalid_query { query(sort: { field: hidden_name, direction: "asc" }) }
    end
  end

  it "rejects SQL injection in sort field and direction" do
    assert_invalid_query { query(sort: "name; DROP TABLE candidates") }
    assert_invalid_query { query(sort: "(SELECT 1)") }
    assert_invalid_query { query(sort: "name", direction: "asc; DROP TABLE candidates") }

    assert Candidate.table_exists?
  end

  it "rejects hidden canonical and legacy filters" do
    assert_invalid_query do
      query(filters: [{ field: "expected_salary", op: "gt", value: 150 }])
    end

    assert_invalid_query do
      query(filters: [{ field: "other_offers", op: "eq", value: true }])
    end

    assert_invalid_query do
      query(legacy_filters: { "salary_min" => "150" })
    end
  end

  it "rejects arbitrary filter fields even in simple hash form" do
    assert_invalid_query do
      query(filters: { "expected_salary" => 200 })
    end

    assert_invalid_query do
      query(legacy_filters: { "arbitrary_column" => "x" })
    end
  end

  it "does not reveal whether an unauthorized field exists" do
    unknown = assert_raises(CandidateList::InvalidQuery) do
      query(sort: "definitely_not_a_field")
    end
    hidden = assert_raises(CandidateList::InvalidQuery) do
      query(sort: "expected_salary")
    end

    # Both external messages are generic by convention.
    assert_equal "invalid list query", unknown.message
    assert_equal hidden.message, unknown.message
  end

  it "builds parameterized allowed filters" do
    relation = query(
      filters: [
        { field: "status", op: "eq", value: "interview" },
        { field: "name", op: "contains", value: "Ali" }
      ]
    )

    assert_equal [@alice.id], relation.pluck(:id)
    assert_includes relation.to_sql, "LIKE '%Ali%' ESCAPE '!'"

    injection_relation = query(
      filters: [{ field: "name", op: "contains", value: "' OR 1 = 1 --" }]
    )
    assert_empty injection_relation.pluck(:id)
  end

  it "treats LIKE wildcards in values as literals" do
    create_candidate!(name: "100% Hidden_match")

    ids = query(filters: [{ field: "name", op: "contains", value: "0% Hidden_" }]).pluck(:id)

    assert_equal 1, ids.length
    assert_equal "100% Hidden_match", Candidate.find(ids.first).name
  end

  it "translates documented legacy flat parameters" do
    ids = query(
      legacy_filters: {
        "q" => "a",
        "status" => "interview",
        "applied_from" => "2026-01-06T00:00:00Z",
        "applied_to" => "2026-01-15T00:00:00Z"
      }
    ).pluck(:id)

    assert_equal [@alice.id], ids
  end

  it "keeps old raw column names working only when registered and allowed" do
    ids = query(legacy_filters: { "candidates.email" => "bob_hidden@example.test" }).pluck(:id)

    assert_equal [@bob.id], ids
  end

  it "casts enum, integer and boolean values strictly" do
    assert_invalid_query do
      query(filters: [{ field: "status", op: "eq", value: "not_a_status" }])
    end

    assert_invalid_query do
      query(filters: [{ field: "id", op: "eq", value: "1 OR 1=1" }])
    end

    admin_ids = query(
      role: :platform_admin,
      filters: [{ field: "interviewing_elsewhere", op: "eq", value: "true" }]
    ).pluck(:id)

    assert_equal [@bob.id], admin_ids
  end

  it "allows authorized roles to use sensitive fields" do
    ids = query(role: :compensation_admin, sort: "expected_salary", direction: "desc").pluck(:id)

    assert_equal [@alice.id, @carol.id, @bob.id], ids
  end

  it "never returns rows outside the supplied tenant scope" do
    ids = query(
      role: :compensation_admin,
      sort: "expected_salary",
      direction: "desc"
    ).pluck(:id)

    refute_includes ids, @other_company.id
  end

  it "keeps paginated order stable when sort values tie" do
    Candidate.where(company_id: 1).update_all(status: "new")

    first_page = CandidateList::Pagination.offset(
      query(sort: "status", direction: "asc"), page: 1, per_page: 2
    ).pluck(:id)
    second_page = CandidateList::Pagination.offset(
      query(sort: "status", direction: "asc"), page: 2, per_page: 2
    ).pluck(:id)

    assert_equal 2, first_page.length
    assert_equal 1, second_page.length
    assert_empty(first_page & second_page)
    assert_equal [@alice.id, @bob.id, @carol.id].sort, (first_page + second_page).sort
  end

  it "exposes only permitted fields to frontend schema endpoint" do
    keys = CATALOG.metadata(:recruiter).map { |field| field[:key] }

    assert_includes keys, :name
    assert_includes keys, :status
    refute_includes keys, :expected_salary
    refute_includes keys, :interviewing_elsewhere
  end
end

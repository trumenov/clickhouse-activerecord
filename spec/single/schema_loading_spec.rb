require 'spec_helper'
require 'clickhouse-activerecord/schema_dumper'

RSpec.describe 'Schema Loading', :migrations do
  let(:model) { ActiveRecord::Base }
  let(:connection) { model.connection }
  let(:database) { connection.instance_variable_get(:@config)[:database] }

  it 'schema define' do
    allow_any_instance_of(ActiveRecord::MigrationContext).to receive(:migrations).
      and_return([double(version: 1)])
    ActiveRecord::Schema.define(version: 2) {}
  end

  describe 'DateTime64 precision' do
    after do
      connection.drop_table(:datetime64_precision_test, if_exists: true)
      connection.drop_table(:datetime64_nullable_precision_test, if_exists: true)
    end

    it 'dumps and creates DateTime64 columns with the original precision' do
      connection.create_table(:datetime64_precision_test, id: false, options: 'MergeTree ORDER BY id') do |t|
        t.integer :id, null: false
        t.datetime :updated_at, precision: 6, null: false
      end

      stream = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, stream)

      expect(stream.string).to include('t.datetime "updated_at", precision: 6, null: false')
      expect(connection.columns(:datetime64_precision_test).find { |column| column.name == 'updated_at' }.sql_type).to eq('DateTime64(6)')
    end

    it 'dumps and creates nullable DateTime64 columns with the original precision' do
      connection.create_table(:datetime64_nullable_precision_test, id: false, options: 'MergeTree ORDER BY id') do |t|
        t.integer :id, null: false
        t.datetime :updated_at, precision: 6
      end

      stream = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, stream)

      expect(stream.string).to match(/^    t\.datetime "updated_at", precision: 6$/)
      expect(connection.columns(:datetime64_nullable_precision_test).find { |column| column.name == 'updated_at' }.sql_type).to eq('Nullable(DateTime64(6))')
    end
  end

  describe 'assign_database_to_subquery' do
    after do
      connection.execute('DROP VIEW IF EXISTS test_view')
      connection.execute('DROP TABLE IF EXISTS test_target')
      connection.execute('DROP TABLE IF EXISTS test_source')
    end

    context 'when column name contains "from"' do
      it 'does not mistake column name for FROM keyword' do
        # Bug: The regex /(?<=from)/ matches "from" anywhere in the query,
        # including in column names like "sourced_from". This causes the next
        # identifier (often a function name) to be incorrectly prefixed with
        # the database name.
        #
        # Example bug:
        #   SELECT sourced_from, now() FROM table
        # Would incorrectly become:
        #   SELECT sourced_from, default.now() FROM default.table
        # Causing: Function with name 'default.now' does not exist

        connection.execute(<<~SQL)
          CREATE TABLE test_source (
            id UInt64,
            sourced_from String
          ) ENGINE = MergeTree ORDER BY id
        SQL

        connection.execute(<<~SQL)
          CREATE TABLE test_target (
            id UInt64,
            sourced_from String,
            created_at DateTime
          ) ENGINE = MergeTree ORDER BY id
        SQL

        # This query should work: column ending in "from" followed by a function
        expect {
          connection.create_table :test_view, view: true, materialized: true, to: 'test_target',
                                 as: 'SELECT id, sourced_from, now() AS created_at FROM test_source' do |t|
          end
        }.not_to raise_error
      end

      it 'correctly adds database prefix only to table name' do
        connection.execute(<<~SQL)
          CREATE TABLE test_source (
            id UInt64
          ) ENGINE = MergeTree ORDER BY id
        SQL

        connection.execute(<<~SQL)
          CREATE TABLE test_target (
            id UInt64,
            created_at DateTime
          ) ENGINE = MergeTree ORDER BY id
        SQL

        connection.create_table :test_view, view: true, materialized: true, to: 'test_target',
                               as: 'SELECT id, now() AS created_at FROM test_source' do |t|
        end

        # Verify the view was created successfully
        # Note: show_create_table strips database prefixes, so we just verify
        # that the view exists and the function wasn't broken by incorrect prefixing
        show_create = connection.show_create_table('test_view')

        # Should NOT have database prefix on function name
        expect(show_create).not_to include("#{database}.now")
        expect(show_create).to include('now()')
      end
    end
  end
end

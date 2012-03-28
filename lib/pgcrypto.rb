require 'pgcrypto/active_record'
require 'pgcrypto/arel'
require 'pgcrypto/column'
require 'pgcrypto/key'
require 'pgcrypto/table_manager'

module PGCrypto
  class << self
    def [](key)
      (@table_manager ||= TableManager.new)[key]
    end

    def keys
      @keys ||= KeyManager.new
    end
  end

  class Error < StandardError; end

  module ClassMethods
    def pgcrypto(*pgcrypto_column_names)
      options = pgcrypto_column_names.last.is_a?(Hash) ? pgcrypto_column_names.pop : {}
      options = {:include => false, :type => :pgp}.merge(options)

      has_many :pgcrypto_columns, :as => :owner, :autosave => true, :class_name => 'PGCrypto::Column', :dependent => :delete_all

      pgcrypto_column_names.map(&:to_s).each do |column_name|
        # Stash the encryption type in our module so various monkeypatches can access it later!
        PGCrypto[table_name][column_name] = options.symbolize_keys

        # Add attribute readers/writers to keep this baby as fluid and clean as possible.
        start_line = __LINE__; pgcrypto_methods = <<-PGCRYPTO_METHODS
        def #{column_name}
          return @_pgcrypto_#{column_name}.try(:value) if defined?(@_pgcrypto_#{column_name})
          @_pgcrypto_#{column_name} ||= select_pgcrypto_column(:#{column_name})
          @_pgcrypto_#{column_name}.try(:value)
        end

        # We write the attribute directly to its child value. Neato!
        def #{column_name}=(value)
          if value.nil?
            pgcrypto_columns.where(:name => "#{column_name}").mark_for_destruction
            remove_instance_variable("@_pgcrypto_#{column_name}") if defined?(@_pgcrypto_#{column_name})
          else
            @_pgcrypto_#{column_name} ||= pgcrypto_columns.select{|column| column.name == "#{column_name}"}.first || pgcrypto_columns.new(:name => "#{column_name}")
            @_pgcrypto_#{column_name}.value = value
          end
        end
        PGCRYPTO_METHODS

        class_eval pgcrypto_methods, __FILE__, start_line
      end

      # If any columns are set to be included in the parent record's finder,
      # we'll go ahead and add 'em!
      if PGCrypto[table_name].any?{|column, options| options[:include] }
        default_scope includes(:pgcrypto_columns)
      end
    end
  end

  module InstanceMethods
    def select_pgcrypto_column(column_name)
      # Now here's the fun part. We want the selector on PGCrypto columns to do the decryption
      # for us, so we have override the SELECT and add a JOIN to build out the decrypted value
      # whenever it's requested.
      options = PGCrypto[self.class.table_name][column_name]
      pgcrypto_column_finder = pgcrypto_columns
      if key = PGCrypto.keys[options[:private_key] || :private]
        pgcrypto_column_finder = pgcrypto_column_finder.select([
          '"pgcrypto_columns"."id"',
          %[pgp_pub_decrypt("pgcrypto_columns"."value", pgcrypto_keys.#{key.name}_key#{", '#{key.password}'" if key.password}) AS "value"]
        ]).joins(%[CROSS JOIN (SELECT #{key.dearmored} AS "#{key.name}_key") AS pgcrypto_keys])
      end
      pgcrypto_column_finder.where(:name => column_name).first
    rescue ActiveRecord::StatementInvalid => e
      case e.message
      when /^PGError: ERROR:  Wrong key or corrupt data/
        # If a column has been corrupted, we'll return nil and let the DBA
        # figure out WTF the is going on
        logger.error(e.message.split("\n").first)
        nil
      else
        raise e
      end
    end
  end
end

PGCrypto.keys[:public] = {:path => '.pgcrypto'} if File.file?('.pgcrypto')
if defined? ActiveRecord::Base
  ActiveRecord::Base.extend PGCrypto::ClassMethods
  ActiveRecord::Base.send :include, PGCrypto::InstanceMethods
end

# coding: utf-8
require 'redis-mutex'

module Sphinx::Integration
  class Transmitter
    attr_reader :klass

    class_attribute :write_disabled

    delegate :full_reindex?, to: :'Sphinx::Integration::Helper'

    def initialize(klass)
      @klass = klass
    end

    # Обновляет запись в сфинксе
    #
    # record - ActiveRecord::Base
    #
    # Returns boolean
    def replace(record)
      return false if write_disabled?

      rt_indexes do |index|
        if (data = transmitted_data(index, record))
          partitions { |partition| ::ThinkingSphinx.replace(index.rt_name(partition), data) }

          if record.exists_in_sphinx?(index.core_name)
            ::ThinkingSphinx.soft_delete(index.core_name_w, record.sphinx_document_id)
          end
        end
      end

      true
    end

    # Удаляет запись из сфинкса
    #
    # record - ActiveRecord::Base
    #
    # Returns boolean
    def delete(record)
      return false if write_disabled?

      rt_indexes do |index|
        partitions { |partition| ::ThinkingSphinx.delete(index.rt_name_w(partition), record.sphinx_document_id) }

        if record.exists_in_sphinx?(index.core_name)
          ::ThinkingSphinx.soft_delete(index.core_name_w, record.sphinx_document_id)
        end
      end

      true
    end

    # Обновление отдельных атрибутов записи
    #
    # record  - ActiveRecord::Base
    # data    - Hash (:field => :value)
    # options - Hash
    #             index_name: String (optional, default: first index)
    #
    # Returns nothing
    def update(record, data, options = {})
      return if write_disabled?

      update_fields(data, {:id => record.sphinx_document_id}, options)
    end

    # Обновление отдельных атрибутов индекса по условию
    #
    # fields  - Hash (:field => value)
    # where   - Hash
    # options - Hash
    #             index_name: String (optional, default: first index)
    #
    # Returns nothing
    def update_fields(fields, where, options = {})
      return if write_disabled?

      if full_reindex?
        options[:index_name] ||= klass.sphinx_indexes.first.name
        ::ThinkingSphinx.find_in_batches(options[:index_name], where) do |ids|
          klass.where(id: ids).each { |record| replace(record) }
        end
      else
        if options[:index_name]
          ::ThinkingSphinx.update(options[:index_name], fields, where)
        else
          rt_indexes do |index|
            ::ThinkingSphinx.update(index.name_w, fields, where)
          end
        end
      end
    end

    private

    # Данные, необходимые для записи в индекс сфинкса
    #
    # index  - ThinkingSphinx::Index
    # record - ActiveRecord::Base
    #
    # Returns Hash
    def transmitted_data(index, record)
      sql = index.single_query_sql.gsub('%{ID}', record.id.to_s)
      if index.local_options[:with_sql] && index.local_options[:with_sql][:update]
        sql = index.local_options[:with_sql][:update].call(sql)
      end
      row = record.class.connection.execute(sql).first
      return unless row
      row.merge!(mva_attributes(index, record))

      row.each do |key, value|
        row[key] = case index.attributes_types_map[key]
          when :integer then value.to_i
          when :float then value.to_f
          when :multi then type_cast_to_multi(value)
          when :boolean then ActiveRecord::ConnectionAdapters::Column.value_to_boolean(value)
          else value
          end
      end

      row
    end

    # MVA data
    #
    # index - ThinkingSphinx::Index
    #
    # Returns Hash
    def mva_attributes(index, record)
      attrs = {}

      index.mva_sources.each do |name, mva_proc|
        attrs[name] = mva_proc.call(record)
      end if index.mva_sources

      attrs
    end

    # Итератор по всем rt индексам
    #
    # Yields ThinkingSphinx::Index
    #
    # Returns nothing
    def rt_indexes
      klass.sphinx_indexes.select(&:rt?).each do |index|
        yield index
      end
    end

    # Итератор по текущим активным частям rt индексов
    #
    # Yields Integer
    def partitions
      if full_reindex?
        yield 0
        yield 1
      else
        yield Sphinx::Integration::Helper.recent_rt.current
      end
    end

    # Привести тип к мульти атрибуту
    #
    # value - NilClass or String or Array
    #
    # Returns Array
    def type_cast_to_multi(value)
      if value.nil?
        []
      elsif value.is_a?(String)
        value.split(',')
      else
        value
      end
    end
  end
end

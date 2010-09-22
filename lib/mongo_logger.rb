require 'uri'
require 'mongo'

class MongoLogger < ActiveSupport::BufferedLogger

  begin
    @mongo_collection_name = "#{Rails.env}_log"
    capsize                = 15.megabytes # TODO: make this configurable

    if ENV['MONGOHQ_URL']
      uri = URI.parse(ENV['MONGOHQ_URL'])
      @mongo_connection ||= Mongo::Connection.new(uri.host, uri.port, :auto_reconnect => true).db(uri.path.gsub(/^\//, ''))
      @mongo_connection.authenticate(uri.user, uri.password)
    else
      app_name            = Rails.root.to_s.split('/').last
      @mongo_connection ||= Mongo::Connection.new('localhost', 27017, :auto_reconnect => true).db("#{app_name}_log")
    end

    # setup the capped collection if it doesn't already exist
    unless @mongo_connection.collection_names.include?(@mongo_collection_name)
      @mongo_connection.create_collection(@mongo_collection_name, {:capped => true, :size => capsize})
    end

  rescue => e
    puts "=> !! A connection to mongo could not be established - the logger will function like a normal ActiveSupport::BufferedLogger !!"
  end

  class << self
    attr_reader :mongo_collection_name, :mongo_connection
  end

  def initialize(level=DEBUG)
    super(File.join(Rails.root, "log/#{Rails.env}.log"), level)
  end

  def level_to_sym(level)
    case level
      when 0 then :debug
      when 1 then :info
      when 2 then :warn
      when 3 then :error
      when 4 then :fatal
      when 5 then :unknown
    end
  end

  def mongoize(options={})   
    @mongo_record = options.merge({
      :messages => Hash.new { |hash, key| hash[key] = Array.new },
      :request_time => Time.now.utc
    })
    runtime = Benchmark.measure do
      yield
    end
    @mongo_record[:runtime]     = (runtime.real * 1000).ceil
    self.class.mongo_connection[self.class.mongo_collection_name].insert(@mongo_record) rescue nil
  end

  def add_metadata(options={})
    options.each_pair do |key, value|
      unless [:messages, :request_time, :ip, :runtime].include?(key.to_sym)
        info("[MongoLogger : metadata] '#{key}' => '#{value}'")
        @mongo_record[key] = value
      else
        raise ArgumentError, ":#{key} is a reserved key for the mongo logger. Please choose a different key"
      end
    end
  end

  def add(severity, message = nil, progname = nil, &block)
    unless @level > severity
      if ActiveRecord::Base.colorize_logging
        # remove colorization done by rails and just save the actual message
        @mongo_record[:messages][level_to_sym(severity)] << message.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip rescue nil
      else
        @mongo_record[:messages][level_to_sym(severity)] << message
      end
    end

    super
  end
end # class MongoLogger

class Fluent::GrepOutput < Fluent::Output
  Fluent::Plugin.register_output('grep', self)

  REGEXP_MAX_NUM = 20

  config_param :input_key, :string, :default => nil # obsolete
  config_param :regexp, :string, :default => nil # obsolete
  config_param :exclude, :string, :default => nil # obsolete
  config_param :tag, :string, :default => nil
  config_param :add_tag_prefix, :string, :default => nil
  config_param :remove_tag_prefix, :string, :default => nil
  config_param :replace_invalid_sequence, :bool, :default => false
  (1..REGEXP_MAX_NUM).each {|i| config_param :"regexp#{i}",  :string, :default => nil }
  (1..REGEXP_MAX_NUM).each {|i| config_param :"exclude#{i}", :string, :default => nil }

  # for test
  attr_reader :regexps
  attr_reader :excludes

  def configure(conf)
    super

    @regexps = {}
    @regexps[@input_key] = Regexp.compile(@regexp) if @input_key and @regexp
    (1..REGEXP_MAX_NUM).each do |i|
      next unless conf["regexp#{i}"]
      key, regexp = conf["regexp#{i}"].split(/ /, 2)
      raise Fluent::ConfigError, "regexp#{i} does not contain 2 parameters" unless regexp
      raise Fluent::ConfigError, "regexp#{i} contains a duplicated key, #{key}" if @regexps[key]
      @regexps[key] = Regexp.compile(regexp)
    end

    @excludes = {}
    @excludes[@input_key] = Regexp.compile(@exclude) if @input_key and @exclude
    (1..REGEXP_MAX_NUM).each do |i|
      next unless conf["exclude#{i}"]
      key, exclude = conf["exclude#{i}"].split(/ /, 2)
      raise Fluent::ConfigError, "exclude#{i} does not contain 2 parameters" unless exclude
      raise Fluent::ConfigError, "exclude#{i} contains a duplicated key, #{key}" if @excludes[key]
      @excludes[key] = Regexp.compile(exclude)
    end

    if @tag.nil? and @add_tag_prefix.nil? and @remove_tag_prefix.nil?
      @add_tag_prefix = 'greped' # not ConfigError to support lower version compatibility
    end

    @tag_prefix = "#{@add_tag_prefix}." if @add_tag_prefix
    @tag_prefix_match = "#{@remove_tag_prefix}." if @remove_tag_prefix
    @tag_proc =
      if @tag
        Proc.new {|tag| @tag }
      elsif @tag_prefix and @tag_prefix_match
        Proc.new {|tag| "#{@tag_prefix}#{lstrip(tag, @tag_prefix_match)}" }
      elsif @tag_prefix_match
        Proc.new {|tag| lstrip(tag, @tag_prefix_match) }
      elsif @tag_prefix
        Proc.new {|tag| "#{@tag_prefix}#{tag}" }
      else
        Proc.new {|tag| tag }
      end
  end

  def emit(tag, es, chain)
    emit_tag = @tag_proc.call(tag)

    es.each do |time,record|
      catch(:break_loop) do
        @regexps.each do |key, regexp|
          throw :break_loop unless match(regexp, record[key].to_s)
        end
        @excludes.each do |key, exclude|
          throw :break_loop if match(exclude, record[key].to_s)
        end
        Fluent::Engine.emit(emit_tag, time, record)
      end
    end

    chain.next
  rescue => e
    $log.warn e.message
    $log.warn e.backtrace.join(', ')
  end

  private

  def lstrip(string, substring)
    string.index(substring) == 0 ? string[substring.size..-1] : string
  end

  def match(regexp, string)
    begin
      return regexp.match(string)
    rescue ArgumentError => e
      raise e unless e.message.index("invalid byte sequence in") == 0
      string = replace_invalid_byte(string)
      retry
    end
    return true
  end

  def replace_invalid_byte(string)
    replace_options = { invalid: :replace, undef: :replace, replace: '?' }
    original_encoding = string.encoding
    temporal_encoding = (original_encoding == Encoding::UTF_8 ? Encoding::UTF_16BE : Encoding::UTF_8)
    string.encode(temporal_encoding, original_encoding, replace_options).encode(original_encoding)
  end

end

# dependencies
require "active_support"
require "openssl"
require "argon2"

# modules
require "blind_index/key_generator"
require "blind_index/model"
require "blind_index/version"

module BlindIndex
  class Error < StandardError; end

  class << self
    attr_accessor :default_options
    attr_writer :master_key
  end
  self.default_options = {}

  def self.master_key
    @master_key ||= ENV["BLIND_INDEX_MASTER_KEY"]
  end

  def self.generate_bidx(value, key:, **options)
    options = {
      encode: true
    }.merge(default_options).merge(options)

    # apply expression
    value = options[:expression].call(value) if options[:expression]

    unless value.nil?
      algorithm = (options[:algorithm] || (options[:legacy] ? :pbkdf2_sha256 : :argon2id)).to_sym
      algorithm = :pbkdf2_sha256 if algorithm == :pbkdf2_hmac
      algorithm = :argon2i if algorithm == :argon2

      key = key.call if key.respond_to?(:call)
      raise BlindIndex::Error, "Missing key for blind index" unless key

      key = key.to_s
      unless options[:insecure_key] && algorithm == :pbkdf2_sha256
        key = decode_key(key)
      end

      # gist to compare algorithm results
      # https://gist.github.com/ankane/fe3ac63fbf1c4550ee12554c664d2b8c
      cost_options = options[:cost] || {}

      # check size
      size = (options[:size] || 32).to_i
      raise BlindIndex::Error, "Size must be between 1 and 32" unless (1..32).include?(size)

      value = value.to_s

      value =
        case algorithm
        when :argon2id
          t = (cost_options[:t] || (options[:slow] ? 4 : 3)).to_i
          # use same bounds as rbnacl
          raise BlindIndex::Error, "t must be between 3 and 10" if t < 3 || t > 10

          # m is memory in kibibytes (1024 bytes)
          m = (cost_options[:m] || (options[:slow] ? 15 : 12)).to_i
          # use same bounds as rbnacl
          raise BlindIndex::Error, "m must be between 3 and 22" if m < 3 || m > 22

          [Argon2::Engine.hash_argon2id(value, key, t, m, size)].pack("H*")
        when :pbkdf2_sha256
          iterations = cost_options[:iterations] || options[:iterations] || (options[:slow] ? 100000 : 10000)
          OpenSSL::PKCS5.pbkdf2_hmac(value, key, iterations, size, "sha256")
        when :argon2i
          t = (cost_options[:t] || 3).to_i
          # use same bounds as rbnacl
          raise BlindIndex::Error, "t must be between 3 and 10" if t < 3 || t > 10

          # m is memory in kibibytes (1024 bytes)
          m = (cost_options[:m] || 12).to_i
          # use same bounds as rbnacl
          raise BlindIndex::Error, "m must be between 3 and 22" if m < 3 || m > 22

          [Argon2::Engine.hash_argon2i(value, key, t, m, size)].pack("H*")
        when :scrypt
          n = cost_options[:n] || 4096
          r = cost_options[:r] || 8
          cp = cost_options[:p] || 1
          SCrypt::Engine.scrypt(value, key, n, r, cp, size)
        else
          raise BlindIndex::Error, "Unknown algorithm"
        end

      encode = options[:encode]
      if encode
        if encode.respond_to?(:call)
          encode.call(value)
        else
          [value].pack(options[:legacy] ? "m" : "m0")
        end
      else
        value
      end
    end
  end

  def self.generate_key
    require "securerandom"
    # force encoding to make JRuby consistent with MRI
    SecureRandom.hex(32).force_encoding(Encoding::US_ASCII)
  end

  def self.index_key(table:, bidx_attribute:, master_key: nil, encode: true)
    master_key ||= BlindIndex.master_key
    raise BlindIndex::Error, "Missing master key" unless master_key

    key = BlindIndex::KeyGenerator.new(master_key).index_key(table: table, bidx_attribute: bidx_attribute)
    key = key.unpack("H*").first if encode
    key
  end

  def self.decode_key(key)
    # decode hex key
    if key.encoding != Encoding::BINARY && key =~ /\A[0-9a-f]{64}\z/i
      key = [key].pack("H*")
    end

    raise BlindIndex::Error, "Key must use binary encoding" if key.encoding != Encoding::BINARY
    raise BlindIndex::Error, "Key must be 32 bytes" if key.bytesize != 32

    key
  end
end

ActiveSupport.on_load(:active_record) do
  require "blind_index/extensions"
  extend BlindIndex::Model

  if defined?(ActiveRecord::TableMetadata)
    ActiveRecord::TableMetadata.prepend(BlindIndex::Extensions::TableMetadata)
  else
    ActiveRecord::PredicateBuilder.singleton_class.prepend(BlindIndex::Extensions::PredicateBuilder)
  end

  ActiveRecord::DynamicMatchers::Method.prepend(BlindIndex::Extensions::DynamicMatchers)

  unless ActiveRecord::VERSION::STRING.start_with?("5.1.")
    ActiveRecord::Validations::UniquenessValidator.prepend(BlindIndex::Extensions::UniquenessValidator)
  end
end

if defined?(Mongoid)
  # TODO find better ActiveModel hook
  require "active_model/callbacks"
  ActiveModel::Callbacks.include(BlindIndex::Model)

  require "blind_index/mongoid"
  Mongoid::Criteria.prepend(BlindIndex::Mongoid::Criteria)
  Mongoid::Validatable::UniquenessValidator.prepend(BlindIndex::Mongoid::UniquenessValidator)
end

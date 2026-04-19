# frozen_string_literal: true

require "json"

module Easyop
  # Thin wrapper around ActiveSupport::MessageEncryptor for symmetrically
  # encrypting/decrypting values stored in OperationLog params_data / result_data.
  #
  # Usage:
  #   encrypted = Easyop::SimpleCrypt.encrypt("4242 4242 4242 4242")
  #   Easyop::SimpleCrypt.decrypt(encrypted) # => "4242 4242 4242 4242"
  #
  # Secret resolution order (first non-blank value wins):
  #   1. Easyop.config.recording_secret
  #   2. ENV["EASYOP_RECORDING_SECRET"]
  #   3. Rails.application.credentials.easyop.recording_secret   (nested namespace)
  #   4. Rails.application.credentials.easyop_recording_secret   (flat key)
  #   5. Rails.application.credentials.secret_key_base           (app fallback)
  #
  # Requires ActiveSupport::MessageEncryptor (part of the activesupport gem).
  module SimpleCrypt
    MissingSecretError = Class.new(StandardError)
    EncryptionError    = Class.new(StandardError)
    DecryptionError    = Class.new(StandardError)

    MARKER_KEY = "$easyop_encrypted".freeze

    # Encrypt +value+ to a ciphertext string using MessageEncryptor.
    def self.encrypt(value, secret: nil)
      crypt(secret).encrypt_and_sign(value)
    rescue MissingSecretError, EncryptionError
      raise
    rescue => e
      raise EncryptionError, "Encryption failed: #{e.message}"
    end

    # Decrypt a ciphertext string previously produced by +encrypt+.
    def self.decrypt(value, secret: nil)
      crypt(secret).decrypt_and_verify(value)
    rescue MissingSecretError, DecryptionError
      raise
    rescue => e
      raise DecryptionError, "Decryption failed: #{e.message}"
    end

    # Returns true when +value+ is the `{ "$easyop_encrypted" => "…" }` marker hash.
    # Accepts both String and Symbol keys (handles JSON.parse round-trips).
    def self.encrypted_marker?(value)
      value.is_a?(Hash) && (value.key?(MARKER_KEY) || value.key?(MARKER_KEY.to_sym))
    end

    # Round-trip helper used by consumers (e.g. a LogRollback service):
    # - If +value+ is not an encrypted marker, returns it unchanged.
    # - Otherwise decrypts and JSON-parses structured payloads (hashes/arrays).
    def self.decrypt_marker(value, secret: nil)
      return value unless encrypted_marker?(value)
      payload = decrypt(value[MARKER_KEY] || value[MARKER_KEY.to_sym], secret: secret)
      return payload unless payload.is_a?(String) && (payload.start_with?("{") || payload.start_with?("["))

      JSON.parse(payload)
    rescue JSON::ParserError
      payload
    end

    # Resolve and validate the encryption secret, then return a MessageEncryptor.
    def self.crypt(secret = nil)
      require "active_support/message_encryptor"

      key = (secret || default_secret).to_s
      raise MissingSecretError, "Encryption secret too short (need ≥32 bytes, got #{key.bytesize})" if key.bytesize < 32

      ActiveSupport::MessageEncryptor.new(key[0..31].bytes.pack("c*"))
    end

    # Resolve the secret from the priority chain. Returns the first non-blank value found.
    #
    #   Priority (highest → lowest):
    #   1. Easyop.config.recording_secret
    #   2. ENV["EASYOP_RECORDING_SECRET"]
    #   3. Rails credentials  →  easyop: { recording_secret: "…" }
    #   4. Rails credentials  →  easyop_recording_secret: "…"
    #   5. Rails credentials  →  secret_key_base: "…"
    #
    # Raises MissingSecretError when no source yields a value, listing every option.
    def self.default_secret
      # 1. Explicit code config — always wins.
      if Easyop.config.respond_to?(:recording_secret)
        key = Easyop.config.recording_secret.to_s
        return key unless key.empty?
      end

      # 2. Environment variable — container / 12-factor friendly.
      key = ENV["EASYOP_RECORDING_SECRET"].to_s
      return key unless key.empty?

      # 3–5. Rails credentials (only when Rails is loaded and the app is initialized).
      if defined?(Rails) && Rails.application
        creds = Rails.application.credentials

        # 3. Nested namespace: credentials.easyop.recording_secret
        #    credentials.yml.enc:
        #      easyop:
        #        recording_secret: <key>
        key = _creds_dig(creds, :easyop, :recording_secret)
        return key if key

        # 4. Flat key: credentials.easyop_recording_secret
        #    credentials.yml.enc:
        #      easyop_recording_secret: <key>
        key = _creds_dig(creds, :easyop_recording_secret)
        return key if key

        # 5. App master secret — works out-of-the-box in development.
        key = _creds_dig(creds, :secret_key_base)
        return key if key
      end

      raise MissingSecretError, <<~MSG.strip
        Easyop::SimpleCrypt: no encryption secret configured. Set one of:

          1.  Easyop.configure { |c| c.recording_secret = "…" }        # code
          2.  ENV["EASYOP_RECORDING_SECRET"] = "…"                      # env var
          3.  Rails credentials → easyop: { recording_secret: "…" }    # nested namespace
          4.  Rails credentials → easyop_recording_secret: "…"         # flat key
          5.  Rails credentials → secret_key_base: "…"                 # app fallback

        The secret must be ≥ 32 bytes.
      MSG
    end

    # Navigate a credentials-like object through one or more keys.
    # Handles all common Rails credential object types:
    #   - ActiveSupport::EncryptedConfiguration (Rails 7+, responds to #dig)
    #   - HashWithIndifferentAccess / OrderedOptions (nested namespace values)
    #   - plain Ruby Hash
    #   - method access (custom credential objects)
    #
    # Returns the resolved string value, or nil if any key in the path is missing
    # or if the final value is itself a Hash (meaning we stopped at a namespace, not a leaf).
    def self._creds_dig(obj, *keys)
      return nil if obj.nil?

      result = keys.reduce(obj) do |cur, key|
        break nil if cur.nil?

        if cur.respond_to?(:dig)
          # #dig works on Rails EncryptedConfiguration, Hash, HashWithIndifferentAccess.
          # Try symbol key first (Rails YAML symbols), then string key for HWIA/plain Hash.
          cur.dig(key) || cur.dig(key.to_s)
        elsif cur.respond_to?(key)
          # OrderedOptions / custom method-access objects.
          cur.public_send(key)
        elsif cur.respond_to?(:[])
          cur[key] || cur[key.to_s]
        else
          break nil
        end
      end

      # A Hash result means we resolved to a namespace, not a leaf — ignore it.
      return nil if result.is_a?(Hash)
      s = result.to_s
      s.empty? ? nil : s
    end
    private_class_method :_creds_dig
  end
end

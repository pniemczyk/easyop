# frozen_string_literal: true

require 'test_helper'
require 'easyop/simple_crypt'

class SimpleCryptTest < Minitest::Test
  VALID_SECRET = "a" * 32

  def setup
    Easyop.configure { |c| c.recording_secret = VALID_SECRET }
  end

  def teardown
    Easyop.reset_config!
    ENV.delete("EASYOP_RECORDING_SECRET")
    _remove_fake_rails
  end

  # ── encrypt / decrypt round-trip ────────────────────────────────────────────

  def test_round_trip_string
    ciphertext = Easyop::SimpleCrypt.encrypt("hello world")
    assert_equal "hello world", Easyop::SimpleCrypt.decrypt(ciphertext)
  end

  def test_round_trip_with_explicit_secret
    secret = "b" * 32
    cipher = Easyop::SimpleCrypt.encrypt("secret", secret: secret)
    assert_equal "secret", Easyop::SimpleCrypt.decrypt(cipher, secret: secret)
  end

  def test_decrypt_with_wrong_secret_raises
    cipher = Easyop::SimpleCrypt.encrypt("data")
    assert_raises(Easyop::SimpleCrypt::DecryptionError) do
      Easyop::SimpleCrypt.decrypt(cipher, secret: "c" * 32)
    end
  end

  def test_tampered_ciphertext_raises_decryption_error
    cipher = Easyop::SimpleCrypt.encrypt("data")
    assert_raises(Easyop::SimpleCrypt::DecryptionError) do
      Easyop::SimpleCrypt.decrypt("not-a-real-cipher")
    end
  end

  # ── encrypted_marker? ───────────────────────────────────────────────────────

  def test_encrypted_marker_true_for_string_key
    assert Easyop::SimpleCrypt.encrypted_marker?({ "$easyop_encrypted" => "x" })
  end

  def test_encrypted_marker_true_for_symbol_key
    assert Easyop::SimpleCrypt.encrypted_marker?({ :"$easyop_encrypted" => "x" })
  end

  def test_encrypted_marker_false_for_plain_hash
    refute Easyop::SimpleCrypt.encrypted_marker?({ foo: "bar" })
  end

  def test_encrypted_marker_false_for_string
    refute Easyop::SimpleCrypt.encrypted_marker?("ciphertext")
  end

  def test_encrypted_marker_false_for_nil
    refute Easyop::SimpleCrypt.encrypted_marker?(nil)
  end

  # ── decrypt_marker ───────────────────────────────────────────────────────────

  def test_decrypt_marker_passthrough_for_non_marker
    assert_equal "plain", Easyop::SimpleCrypt.decrypt_marker("plain")
    assert_equal 42,      Easyop::SimpleCrypt.decrypt_marker(42)
    assert_equal nil,     Easyop::SimpleCrypt.decrypt_marker(nil)
  end

  def test_decrypt_marker_round_trips_plaintext
    marker = { "$easyop_encrypted" => Easyop::SimpleCrypt.encrypt("hello") }
    assert_equal "hello", Easyop::SimpleCrypt.decrypt_marker(marker)
  end

  def test_decrypt_marker_json_parses_structured_payload
    hash_value = { "id" => 1, "class" => "User" }
    payload    = hash_value.to_json
    marker     = { "$easyop_encrypted" => Easyop::SimpleCrypt.encrypt(payload) }
    assert_equal hash_value, Easyop::SimpleCrypt.decrypt_marker(marker)
  end

  def test_decrypt_marker_accepts_symbol_key
    marker = { :"$easyop_encrypted" => Easyop::SimpleCrypt.encrypt("sym") }
    assert_equal "sym", Easyop::SimpleCrypt.decrypt_marker(marker)
  end

  # ── secret validation ────────────────────────────────────────────────────────

  def test_short_secret_raises
    assert_raises(Easyop::SimpleCrypt::MissingSecretError) do
      Easyop::SimpleCrypt.encrypt("data", secret: "tooshort")
    end
  end

  def test_exactly_32_byte_secret_is_valid
    secret = "x" * 32
    cipher = Easyop::SimpleCrypt.encrypt("ok", secret: secret)
    assert_equal "ok", Easyop::SimpleCrypt.decrypt(cipher, secret: secret)
  end

  # ── secret resolution priority chain ────────────────────────────────────────

  def test_missing_secret_raises_with_helpful_message
    Easyop.reset_config!
    err = assert_raises(Easyop::SimpleCrypt::MissingSecretError) do
      Easyop::SimpleCrypt.encrypt("data")
    end
    # Message must list all 5 configuration options.
    assert_match "recording_secret",            err.message
    assert_match "EASYOP_RECORDING_SECRET",     err.message
    assert_match "easyop: { recording_secret:", err.message
    assert_match "easyop_recording_secret:",    err.message
    assert_match "secret_key_base",             err.message
    assert_match "32",                          err.message
  end

  # 1. Easyop.config.recording_secret
  def test_config_recording_secret_is_used
    Easyop.configure { |c| c.recording_secret = VALID_SECRET }
    cipher = Easyop::SimpleCrypt.encrypt("from_config")
    assert_equal "from_config", Easyop::SimpleCrypt.decrypt(cipher)
  end

  # 2. ENV["EASYOP_RECORDING_SECRET"]
  def test_env_var_used_when_config_is_blank
    Easyop.reset_config!
    ENV["EASYOP_RECORDING_SECRET"] = "e" * 32
    cipher = Easyop::SimpleCrypt.encrypt("from_env")
    assert_equal "from_env", Easyop::SimpleCrypt.decrypt(cipher)
  end

  # Priority: config > env
  def test_config_wins_over_env_var
    env_secret    = "e" * 32
    config_secret = "c" * 32

    Easyop.configure { |c| c.recording_secret = config_secret }
    ENV["EASYOP_RECORDING_SECRET"] = env_secret

    # Encrypting with config_secret must NOT be decryptable with env_secret.
    cipher = Easyop::SimpleCrypt.encrypt("priority", secret: config_secret)
    assert_raises(Easyop::SimpleCrypt::DecryptionError) do
      Easyop::SimpleCrypt.decrypt(cipher, secret: env_secret)
    end
    assert_equal "priority", Easyop::SimpleCrypt.decrypt(cipher, secret: config_secret)
  end

  # 3. Rails credentials → easyop: { recording_secret: "…" }  (nested namespace)
  def test_rails_nested_credentials_easyop_recording_secret
    Easyop.reset_config!
    secret = "f" * 32
    with_fake_rails(easyop: { recording_secret: secret }) do
      cipher = Easyop::SimpleCrypt.encrypt("nested_creds")
      assert_equal "nested_creds", Easyop::SimpleCrypt.decrypt(cipher, secret: secret)
    end
  end

  # 4. Rails credentials → easyop_recording_secret: "…"  (flat key)
  def test_rails_flat_credentials_easyop_recording_secret
    Easyop.reset_config!
    secret = "g" * 32
    with_fake_rails(easyop_recording_secret: secret) do
      cipher = Easyop::SimpleCrypt.encrypt("flat_creds")
      assert_equal "flat_creds", Easyop::SimpleCrypt.decrypt(cipher, secret: secret)
    end
  end

  # 5. Rails credentials → secret_key_base  (app master secret fallback)
  def test_rails_secret_key_base_fallback
    Easyop.reset_config!
    secret = "h" * 32
    with_fake_rails(secret_key_base: secret) do
      cipher = Easyop::SimpleCrypt.encrypt("from_skb")
      assert_equal "from_skb", Easyop::SimpleCrypt.decrypt(cipher, secret: secret)
    end
  end

  # Priority: nested creds > flat key > secret_key_base
  def test_rails_nested_credentials_wins_over_flat
    Easyop.reset_config!
    nested_secret = "i" * 32
    flat_secret   = "j" * 32

    with_fake_rails(easyop: { recording_secret: nested_secret }, easyop_recording_secret: flat_secret) do
      # Must use nested_secret (higher priority).
      cipher = Easyop::SimpleCrypt.encrypt("nested_wins", secret: nested_secret)
      assert_equal "nested_wins", Easyop::SimpleCrypt.decrypt(cipher, secret: nested_secret)
      assert_raises(Easyop::SimpleCrypt::DecryptionError) do
        Easyop::SimpleCrypt.decrypt(cipher, secret: flat_secret)
      end
    end
  end

  # Priority: flat key > secret_key_base
  def test_rails_flat_credentials_wins_over_secret_key_base
    Easyop.reset_config!
    flat_secret   = "k" * 32
    skb_secret    = "l" * 32

    with_fake_rails(easyop_recording_secret: flat_secret, secret_key_base: skb_secret) do
      cipher = Easyop::SimpleCrypt.encrypt("flat_wins", secret: flat_secret)
      assert_equal "flat_wins", Easyop::SimpleCrypt.decrypt(cipher, secret: flat_secret)
      assert_raises(Easyop::SimpleCrypt::DecryptionError) do
        Easyop::SimpleCrypt.decrypt(cipher, secret: skb_secret)
      end
    end
  end

  # Priority: env > all Rails creds
  def test_env_var_wins_over_rails_credentials
    Easyop.reset_config!
    env_secret  = "m" * 32
    rails_secret = "n" * 32

    ENV["EASYOP_RECORDING_SECRET"] = env_secret
    with_fake_rails(easyop: { recording_secret: rails_secret }, secret_key_base: rails_secret) do
      cipher = Easyop::SimpleCrypt.encrypt("env_wins", secret: env_secret)
      assert_equal "env_wins", Easyop::SimpleCrypt.decrypt(cipher, secret: env_secret)
      assert_raises(Easyop::SimpleCrypt::DecryptionError) do
        Easyop::SimpleCrypt.decrypt(cipher, secret: rails_secret)
      end
    end
  end

  # Priority: config > env > Rails — complete chain
  def test_config_is_highest_priority_in_full_chain
    config_secret = "o" * 32
    env_secret    = "p" * 32
    rails_secret  = "q" * 32

    Easyop.configure { |c| c.recording_secret = config_secret }
    ENV["EASYOP_RECORDING_SECRET"] = env_secret
    with_fake_rails(easyop: { recording_secret: rails_secret }, secret_key_base: rails_secret) do
      cipher = Easyop::SimpleCrypt.encrypt("top_priority", secret: config_secret)
      assert_equal "top_priority", Easyop::SimpleCrypt.decrypt(cipher, secret: config_secret)
      assert_raises(Easyop::SimpleCrypt::DecryptionError) do
        Easyop::SimpleCrypt.decrypt(cipher, secret: env_secret)
      end
      assert_raises(Easyop::SimpleCrypt::DecryptionError) do
        Easyop::SimpleCrypt.decrypt(cipher, secret: rails_secret)
      end
    end
  end

  # _creds_dig handles the various Rails credential object shapes
  def test_creds_dig_resolves_nested_hash_path
    creds = FakeCredentials.new(easyop: { recording_secret: "nested_value" })
    result = Easyop::SimpleCrypt.send(:_creds_dig, creds, :easyop, :recording_secret)
    assert_equal "nested_value", result
  end

  def test_creds_dig_resolves_flat_key
    creds = FakeCredentials.new(easyop_recording_secret: "flat_value")
    result = Easyop::SimpleCrypt.send(:_creds_dig, creds, :easyop_recording_secret)
    assert_equal "flat_value", result
  end

  def test_creds_dig_returns_nil_for_missing_key
    creds = FakeCredentials.new({})
    assert_nil Easyop::SimpleCrypt.send(:_creds_dig, creds, :easyop, :recording_secret)
    assert_nil Easyop::SimpleCrypt.send(:_creds_dig, creds, :easyop_recording_secret)
  end

  def test_creds_dig_returns_nil_when_path_stops_at_hash_namespace
    # If the path resolves to a Hash (a namespace, not a leaf), return nil.
    creds = FakeCredentials.new(easyop: { recording_secret: "x" * 32 })
    result = Easyop::SimpleCrypt.send(:_creds_dig, creds, :easyop)
    assert_nil result
  end

  def test_creds_dig_accepts_string_keyed_hash
    # HashWithIndifferentAccess / plain Hash with string keys
    creds = FakeCredentials.new("easyop" => { "recording_secret" => "str_key_value" })
    result = Easyop::SimpleCrypt.send(:_creds_dig, creds, :easyop, :recording_secret)
    assert_equal "str_key_value", result
  end

  def test_creds_dig_handles_nil_object
    assert_nil Easyop::SimpleCrypt.send(:_creds_dig, nil, :any_key)
  end

  private

  # ── Fake Rails credential helpers ───────────────────────────────────────────

  # Simulates Rails.application.credentials with nested hash access.
  # Supports both #dig (Rails 7+ style) and method_missing (OrderedOptions style),
  # and handles both symbol and string keys (HashWithIndifferentAccess style).
  class FakeCredentials
    def initialize(hash)
      @hash = deep_symbolize(hash)
    end

    def dig(*keys)
      keys.reduce(@hash) do |acc, key|
        case acc
        when Hash then acc[key.to_sym] || acc[key.to_s.to_sym]
        else           nil
        end
      end
    end

    def respond_to_missing?(name, include_private = false)
      @hash.key?(name.to_sym) || super
    end

    def method_missing(name, *args)
      return super unless @hash.key?(name.to_sym)
      val = @hash[name.to_sym]
      val.is_a?(Hash) ? FakeCredentials.new(val) : val
    end

    private

    def deep_symbolize(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      else           obj
      end
    end
  end

  def with_fake_rails(**credentials_hash)
    creds = FakeCredentials.new(credentials_hash)
    app   = Struct.new(:credentials).new(creds)

    unless defined?(::Rails)
      Object.const_set("Rails", Module.new { define_singleton_method(:application) { app } })
    end
    yield
  ensure
    _remove_fake_rails
  end

  def _remove_fake_rails
    Object.send(:remove_const, :Rails) if defined?(::Rails)
  rescue NameError
    # already gone
  end
end

# frozen_string_literal: true

require 'puppet_x'
require 'openssl'
require 'base64'

module PuppetX::AcmeKvstore
  # AES-256-GCM encryption of private keys, stored as
  #   { "version": 1, "iv": "<base64>", "tag": "<base64>", "data": "<base64>" }
  # with the same associated data as CCI-UI (see #aad), so both can read
  # each other's keys and an envelope cannot be moved to another version.
  class Crypto
    CRYPT_VERSION = 1
    IV_BYTES  = 12
    TAG_BYTES = 16
    KEY_BYTES = 32

    # CCI-UI's associated data; independent of the KV prefix and backend.
    def self.aad(area, certid, version)
      "cci:#{area}:#{certid}/#{version}"
    end

    # @param plaintext [String] the private key to encrypt (PEM).
    # @param key32 [String] 32-byte area secret (raw, not base64).
    # @param aad [String] see .aad
    # @return [Hash] JSON-serialisable document in the format above.
    def self.encrypt(plaintext, key32, aad:)
      assert_key_length!(key32)

      iv = OpenSSL::Random.random_bytes(IV_BYTES)
      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.encrypt
      cipher.key = key32
      cipher.iv = iv
      cipher.auth_data = aad

      ciphertext = cipher.update(plaintext.to_s) + cipher.final
      tag = cipher.auth_tag(TAG_BYTES)

      {
        'version' => CRYPT_VERSION,
        'iv'      => Base64.strict_encode64(iv),
        'tag'     => Base64.strict_encode64(tag),
        'data'    => Base64.strict_encode64(ciphertext),
      }
    end

    # @param doc [Hash] as produced by .encrypt (string or symbol keys).
    # @param key32 [String] 32-byte area secret (raw, not base64).
    # @param aad [String] see .aad; must match the one used for encryption
    # @return [String] the decrypted private key (PEM).
    def self.decrypt(doc, key32, aad:)
      assert_key_length!(key32)
      doc = stringify_keys(doc)

      raise ArgumentError, "Unknown crypt version: #{doc['version'].inspect}" \
        unless doc['version'].to_i == CRYPT_VERSION

      iv  = Base64.decode64(doc['iv'])
      tag = Base64.decode64(doc['tag'])
      raise ArgumentError, "IV must be #{IV_BYTES} bytes long, was #{iv.bytesize}" unless iv.bytesize == IV_BYTES
      raise ArgumentError, "Tag must be #{TAG_BYTES} bytes long, was #{tag.bytesize}" unless tag.bytesize == TAG_BYTES

      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.decrypt
      cipher.key = key32
      cipher.iv = iv
      cipher.auth_tag = tag
      cipher.auth_data = aad

      cipher.update(Base64.decode64(doc['data'])) + cipher.final
    end

    # Accepts raw, hex or base64; must yield exactly 32 bytes.
    def self.decode_area_secret(secret)
      raise ArgumentError, 'area_secret must not be empty' if secret.nil? || secret.to_s.empty?
      return secret if secret.bytesize == KEY_BYTES

      if secret =~ %r{\A[0-9a-fA-F]{64}\z}
        [secret].pack('H*')
      else
        Base64.decode64(secret)
      end
    end

    def self.assert_key_length!(key32)
      raise ArgumentError, "AES-256-GCM requires a #{KEY_BYTES}-byte key, got #{key32.bytesize}" \
        unless key32.bytesize == KEY_BYTES
    end
    private_class_method :assert_key_length!

    def self.stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end
    private_class_method :stringify_keys
  end
end

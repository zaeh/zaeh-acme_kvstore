# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/crypto'

describe PuppetX::AcmeKvstore::Crypto do
  let(:key) { OpenSSL::Random.random_bytes(32) }
  let(:plaintext) { "-----BEGIN PRIVATE KEY-----\nfakekeydata\n-----END PRIVATE KEY-----\n" }
  let(:aad) { described_class.aad('web', 'shop-example-com', 3) }

  describe '.encrypt / .decrypt' do
    it 'returns a document in the specified format' do
      doc = described_class.encrypt(plaintext, key, aad:)

      expect(doc['version']).to eq(1)
      expect(Base64.decode64(doc['iv']).bytesize).to eq(12)
      expect(Base64.decode64(doc['tag']).bytesize).to eq(16)
      expect(doc['data']).to be_a(String)
    end

    it 'returns the original plaintext after a round trip' do
      doc = described_class.encrypt(plaintext, key, aad:)
      expect(described_class.decrypt(doc, key, aad:)).to eq(plaintext)
    end

    it 'generates a fresh IV on every call' do
      doc1 = described_class.encrypt(plaintext, key, aad:)
      doc2 = described_class.encrypt(plaintext, key, aad:)
      expect(doc1['iv']).not_to eq(doc2['iv'])
    end

    it 'rejects the wrong key when decrypting' do
      doc = described_class.encrypt(plaintext, key, aad:)
      other_key = OpenSSL::Random.random_bytes(32)
      expect { described_class.decrypt(doc, other_key, aad:) }.to raise_error(OpenSSL::Cipher::CipherError)
    end

    it 'rejects keys that are not 32 bytes long' do
      expect { described_class.encrypt(plaintext, 'tooshort', aad:) }.to raise_error(ArgumentError, %r{32-byte})
    end

    it 'rejects an unknown crypt version when decrypting' do
      doc = described_class.encrypt(plaintext, key, aad:)
      doc['version'] = 99
      expect { described_class.decrypt(doc, key, aad:) }.to raise_error(ArgumentError, %r{crypt version})
    end
  end

  describe 'associated data (CCI-UI compatibility)' do
    # CCI-UI's Certificates::Vault, reduced to the cipher operations.
    def cci_encrypt(pem, key32, area, id)
      cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
      cipher.key = key32
      iv = cipher.random_iv
      cipher.auth_data = "cci:#{area}:#{id}"
      data = cipher.update(pem) + cipher.final
      { 'version' => 1, 'iv' => Base64.strict_encode64(iv), 'tag' => Base64.strict_encode64(cipher.auth_tag),
        'data' => Base64.strict_encode64(data), }
    end

    def cci_decrypt(doc, key32, area, id)
      cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
      cipher.key = key32
      cipher.iv = Base64.strict_decode64(doc['iv'])
      cipher.auth_tag = Base64.strict_decode64(doc['tag'])
      cipher.auth_data = "cci:#{area}:#{id}"
      cipher.update(Base64.strict_decode64(doc['data'])) + cipher.final
    end

    it 'is cci:<area>:<certid>/<version>, independent of the KV prefix' do
      expect(described_class.aad('web', 'shop-example-com', 3)).to eq('cci:web:shop-example-com/3')
    end

    it 'produces envelopes CCI-UI can decrypt' do
      doc = described_class.encrypt(plaintext, key, aad:)
      expect(cci_decrypt(doc, key, 'web', 'shop-example-com/3')).to eq(plaintext)
    end

    it 'decrypts envelopes written by CCI-UI' do
      doc = cci_encrypt(plaintext, key, 'web', 'shop-example-com/3')
      expect(described_class.decrypt(doc, key, aad:)).to eq(plaintext)
    end

    it 'refuses an envelope moved to another area, certid or version' do
      doc = described_class.encrypt(plaintext, key, aad:)
      [%w[internal shop-example-com 3], %w[web other 3], %w[web shop-example-com 4]].each do |area, certid, version|
        expect { described_class.decrypt(doc, key, aad: described_class.aad(area, certid, version)) }
          .to raise_error(OpenSSL::Cipher::CipherError)
      end
    end
  end

  describe '.decode_area_secret' do
    it 'accepts a key that is already 32 raw bytes' do
      raw = OpenSSL::Random.random_bytes(32)
      expect(described_class.decode_area_secret(raw)).to eq(raw)
    end

    it 'decodes a hex-encoded key' do
      raw = OpenSSL::Random.random_bytes(32)
      hex = raw.unpack1('H*')
      expect(described_class.decode_area_secret(hex)).to eq(raw)
    end

    it 'decodes a base64-encoded key' do
      raw = OpenSSL::Random.random_bytes(32)
      b64 = Base64.strict_encode64(raw)
      expect(described_class.decode_area_secret(b64)).to eq(raw)
    end

    it 'rejects an empty secret' do
      expect { described_class.decode_area_secret('') }.to raise_error(ArgumentError)
    end
  end
end

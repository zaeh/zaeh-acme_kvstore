# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/acme_kvstore/kv_document'

describe PuppetX::AcmeKvstore::KvDocument do
  describe '.meta' do
    it 'builds the meta document exactly as specified' do
      doc = described_class.meta(
        active_version: 3,
        latest_version: 5,
        status: 'active',
        updated_at: '2026-09-21T10:00:00.000000Z',
        client: 'acme-kvstore',
        updated_by: 'user-subject',
      )

      expect(doc).to eq(
        'active_version' => 3,
        'latest_version' => 5,
        'status'         => 'active',
        'updated_at'     => '2026-09-21T10:00:00.000000Z',
        'client'         => 'acme-kvstore',
        'updated_by'     => 'user-subject',
      )
    end

    it 'adds the acme_renewal summary when given' do
      summary = described_class.renewal_summary(
        not_after: Time.utc(2026, 12, 20, 10), domains: ['shop.example.com'], key_type: :ec, key_size: 384,
      )
      doc = described_class.meta(
        active_version: 1, latest_version: 1, status: 'active', updated_at: 'now',
        client: 'puppet', updated_by: 'worker1.example.com', acme_renewal: summary
      )

      expect(doc['acme_renewal']).to eq(
        'not_after' => '2026-12-20T10:00:00Z', 'domains' => ['shop.example.com'], 'key_type' => 'ec', 'key_size' => 384,
      )
      expect(doc).not_to have_key('active')
    end
  end

  describe '.certificate' do
    it 'always contains pem, tags (empty), has_key, created_at and client - the fields CCI-UI requires' do
      doc = described_class.certificate(
        pem: 'PEMDATA',
        has_key: true,
        created_at: '2026-09-21T10:00:00.000000Z',
        client: 'puppet',
      )

      expect(doc).to eq('pem' => 'PEMDATA', 'tags' => [], 'has_key' => true, 'created_at' => '2026-09-21T10:00:00.000000Z', 'client' => 'puppet')
    end

    it 'includes tags and created_by when supplied' do
      doc = described_class.certificate(
        pem: 'PEMDATA',
        has_key: true,
        created_at: '2026-09-21T10:00:00.000000Z',
        client: 'acme-kvstore',
        tags: %w[Tag1 Tag2],
        created_by: 'user-subject',
      )

      expect(doc['tags']).to eq(%w[Tag1 Tag2])
      expect(doc['created_by']).to eq('user-subject')
    end
  end

  describe 'certificate helpers' do
    def make_cert(subject:, key: OpenSSL::PKey::RSA.new(1024), san: nil)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse(subject)
      cert.public_key = (key.respond_to?(:public_key) && key.is_a?(OpenSSL::PKey::RSA)) ? key.public_key : key
      cert.not_before = Time.utc(2026, 1, 1)
      cert.not_after = Time.utc(2026, 12, 20, 10)
      if san
        ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
        cert.add_extension(ef.create_extension('subjectAltName', san))
      end
      cert.sign(key, OpenSSL::Digest.new('SHA256'))
      cert
    end

    it 'computes the SHA-256 fingerprint' do
      cert = make_cert(subject: '/CN=R11')
      expect(described_class.fingerprint(cert)).to eq(OpenSSL::Digest::SHA256.hexdigest(cert.to_der))
      expect(described_class.fingerprint(cert)).to match(%r{\A[0-9a-f]{64}\z})
    end

    describe '.issuer_certid (<cn>_<expiry date>)' do
      {
        "/C=US/O=Let's Encrypt/CN=R11" => 'r11',
        '/C=US/O=Internet Security Research Group/CN=ISRG Root X1' => 'isrg-root-x1',
        '/C=GB/ST=Greater Manchester/L=Salford/O=COMODO CA Limited/CN=COMODO RSA Certification Authority' =>
          'comodo-rsa-certification-authority',
        '/O=Example Corp./OU=PKI' => 'example-corp',
        '/OU=Only Unit' => 'ca',
      }.each do |subject, label|
        it "is #{label}_<date> for #{subject}" do
          expect(described_class.issuer_certid(make_cert(subject:))).to eq("#{label}_2026-12-20")
        end
      end

      # Decoded by ASN.1 type like CCI-UI, so both derive the same certid.
      def cert_with_name(entries)
        cert = make_cert(subject: '/CN=placeholder')
        name = OpenSSL::X509::Name.new
        entries.each { |key, value, type| name.add_entry(key, value, type) }
        cert.subject = name
        cert
      end

      it 'decodes a CN stored as BMPString (UTF-16)' do
        cert = cert_with_name([['CN', 'Root X1'.encode('UTF-16BE').b, OpenSSL::ASN1::BMPSTRING]])
        expect(described_class.issuer_certid(cert)).to eq('root-x1_2026-12-20')
      end

      it 'decodes a CN stored as UniversalString (UTF-32)' do
        cert = cert_with_name([['CN', 'Root X2'.encode('UTF-32BE').b, OpenSSL::ASN1::UNIVERSALSTRING]])
        expect(described_class.issuer_certid(cert)).to eq('root-x2_2026-12-20')
      end

      it 'decodes an O stored as BMPString when there is no CN' do
        cert = cert_with_name([['O', 'Example CA'.encode('UTF-16BE').b, OpenSSL::ASN1::BMPSTRING]])
        expect(described_class.issuer_certid(cert)).to eq('example-ca_2026-12-20')
      end

      it 'turns non-ASCII letters into separators (UTF8String)' do
        cert = cert_with_name([['CN', 'Ährenwerk Root', OpenSSL::ASN1::UTF8STRING]])
        expect(described_class.issuer_certid(cert)).to eq('hrenwerk-root_2026-12-20')
      end

      it 'uses the expiry date in UTC' do
        cert = make_cert(subject: '/CN=R11')
        cert.not_after = Time.new(2027, 3, 13, 0, 30, 0, '+02:00')
        expect(described_class.issuer_certid(cert)).to eq('r11_2027-03-12')
      end

      it 'keeps names within the certid rules, even for an overlong CN' do
        certid = described_class.issuer_certid(make_cert(subject: "/CN=#{'x' * 150}"))
        expect(certid).to eq("#{'x' * 100}_2026-12-20")
        expect(certid).to match(%r{\A[A-Za-z0-9_.-]{1,120}\z})
      end

      it 'has an alternative with 8 fingerprint characters for another certificate of the same name' do
        cert = make_cert(subject: '/CN=R11')
        expect(described_class.issuer_certid_alternative(cert)).to eq("r11_2026-12-20_#{described_class.fingerprint(cert)[0, 8]}")
      end
    end

    it 'splits a PEM bundle into its certificates' do
      one = make_cert(subject: '/CN=one')
      two = make_cert(subject: '/CN=two')
      expect(described_class.split_pem(one.to_pem + two.to_pem).map(&:to_der)).to eq([one.to_der, two.to_der])
      expect(described_class.split_pem(nil)).to eq([])
    end

    it 'derives a renewal summary from an RSA certificate itself (CN first, then the other DNS names)' do
      cert = make_cert(subject: '/CN=shop.example.com', san: 'DNS:www.shop.example.com,DNS:shop.example.com')
      expect(described_class.summary_of(cert, version: 3)).to eq(
        'not_after' => '2026-12-20T10:00:00Z', 'domains' => ['shop.example.com', 'www.shop.example.com'],
        'key_type' => 'rsa', 'key_size' => 1024, 'version' => 3
      )
    end

    it 'derives the key size of an EC certificate from its curve' do
      cert = make_cert(subject: '/CN=ec.example.com', key: OpenSSL::PKey::EC.generate('secp384r1'))
      expect(described_class.summary_of(cert, version: 1)).to include('key_type' => 'ec', 'key_size' => 384)
    end

    it 'stores version and issuers in acme_renewal when given' do
      summary = described_class.renewal_summary(
        not_after: Time.utc(2026, 12, 20, 10), domains: ['a.example.com'], key_type: :rsa, key_size: 2048, version: 2, issuers: ['f' * 64],
      )
      expect(summary).to include('version' => 2, 'issuers' => ['f' * 64])
    end
  end

  describe '.now_iso8601' do
    it 'returns a UTC timestamp with microseconds and a Z suffix' do
      expect(described_class.now_iso8601).to match(%r{\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z})
    end
  end

  describe 'KV key layout' do
    let(:paths) do
      [
        described_class.meta_path('web', 'shop-example-com'),
        described_class.cert_path('web', 'shop-example-com', 3),
        described_class.key_path('web', 'shop-example-com', 3),
      ]
    end

    it 'places every key below <area>/, so area-scoped ACL tokens can be limited to their own area' do
      expect(paths).to eq(
        [
          'web/certids/shop-example-com',
          'web/certs/shop-example-com/3',
          'web/keys/shop-example-com/3',
        ],
      )
    end

    it 'keeps the same certid in two areas apart' do
      other_area = [
        described_class.meta_path('internal', 'shop-example-com'),
        described_class.cert_path('internal', 'shop-example-com', 3),
      ]
      expect(paths & other_area).to be_empty
    end
  end
end

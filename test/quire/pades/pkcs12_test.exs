defmodule Quire.Pades.Pkcs12Test do
  use ExUnit.Case, async: true

  describe "parse/2" do
    test "parses minimal RSA PKCS#12" do
      p12 = File.read!("test/support/fixtures/minimal.p12")
      assert {:ok, keys, certs} = Quire.Pades.Pkcs12.parse(p12, "a")
      assert length(keys) == 1
      assert length(certs) == 1
      assert hd(keys).algorithm == :rsa
      assert byte_size(hd(keys).key_der) > 100
      assert byte_size(hd(certs).der) > 100
    end

    test "parses RSA legacy PKCS#12" do
      p12 = File.read!("test/support/fixtures/test_rsa_legacy.p12")
      assert {:ok, keys, certs} = Quire.Pades.Pkcs12.parse(p12, "testpass")
      assert length(keys) == 1
      assert length(certs) == 1
      assert hd(keys).algorithm == :rsa
      assert byte_size(hd(keys).key_der) > 100
    end

    test "parses ECDSA legacy PKCS#12" do
      p12 = File.read!("test/support/fixtures/test_ecdsa_legacy.p12")
      assert {:ok, keys, certs} = Quire.Pades.Pkcs12.parse(p12, "testpass")
      assert length(keys) == 1
      assert length(certs) == 1
      assert hd(keys).algorithm == :ecdsa
      assert byte_size(hd(keys).key_der) > 100
    end

    test "handles wrong password gracefully" do
      p12 = File.read!("test/support/fixtures/minimal.p12")
      # Correct password: 1 key
      assert {:ok, keys, _certs} = Quire.Pades.Pkcs12.parse(p12, "a")
      assert length(keys) == 1
      # Wrong password: no crash, keys may be garbage but no error
      assert {:ok, _keys, _certs} = Quire.Pades.Pkcs12.parse(p12, "wrong")
    end

    test "returns error with invalid binary" do
      assert {:error, _} = Quire.Pades.Pkcs12.parse(<<0, 1, 2, 3>>, "pass")
    end

    test "returns error with empty binary" do
      assert {:error, _} = Quire.Pades.Pkcs12.parse(<<>>, "pass")
    end
  end
end

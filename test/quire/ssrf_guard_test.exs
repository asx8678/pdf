defmodule Quire.SsrfGuardTest do
  use Quire.DataCase, async: true

  alias Quire.SsrfGuard

  describe "check/1" do
    test "allows public HTTPS URLs" do
      assert :ok = SsrfGuard.check("https://example.com")
      assert :ok = SsrfGuard.check("https://api.github.com/repos/asx8678/pdf")
      assert :ok = SsrfGuard.check("http://93.184.216.34")
    end

    test "rejects localhost" do
      assert {:error, msg} = SsrfGuard.check("http://localhost:8080")
      assert msg =~ "localhost"

      assert {:error, _msg} = SsrfGuard.check("http://127.0.0.1")
      assert {:error, _msg} = SsrfGuard.check("http://[::1]")
    end

    test "rejects RFC1918 private IPs" do
      assert {:error, msg} = SsrfGuard.check("http://10.0.0.1/health")
      assert msg =~ "RFC1918"

      assert {:error, msg} = SsrfGuard.check("http://172.16.0.5")
      assert msg =~ "RFC1918"

      assert {:error, msg} = SsrfGuard.check("http://192.168.1.1/admin")
      assert msg =~ "RFC1918"
    end

    test "rejects link-local addresses" do
      assert {:error, msg} = SsrfGuard.check("http://169.254.169.254/latest/meta-data")
      assert msg =~ "link-local"
    end

    test "rejects disallowed schemes" do
      assert {:error, msg} = SsrfGuard.check("file:///etc/passwd")
      assert msg =~ "Scheme"

      assert {:error, msg} = SsrfGuard.check("ftp://files.example.com")
      assert msg =~ "Scheme"
    end

    test "rejects URLs without a host" do
      assert {:error, _msg} = SsrfGuard.check("/health")
    end

    test "rejects URLs without a scheme" do
      assert {:error, _msg} = SsrfGuard.check("example.com")
    end

    test "rejects IPv6 loopback" do
      assert {:error, msg} = SsrfGuard.check("http://[::1]:8080/health")
      assert msg =~ "localhost" or msg =~ "loopback"

      assert {:error, msg} = SsrfGuard.check("http://[0:0:0:0:0:0:0:1]")
      assert msg =~ "loopback"
    end

    test "rejects IPv6 unique-local" do
      assert {:error, msg} = SsrfGuard.check("http://[fc00::1]")
      assert msg =~ "unique-local"

      assert {:error, msg} = SsrfGuard.check("http://[fd12:3456::1]")
      assert msg =~ "unique-local"
    end

    test "rejects IPv6 link-local" do
      assert {:error, msg} = SsrfGuard.check("http://[fe80::1]")
      assert msg =~ "link-local"
    end

    test "accepts hostnames that resolve to public IPs" do
      assert :ok = SsrfGuard.check("https://github.com")
      assert :ok = SsrfGuard.check("https://www.google.com")
    end
  end
end

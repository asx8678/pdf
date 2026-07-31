defmodule Quire.SsrfGuard do
  @moduledoc ~S"""
  SSRF (Server-Side Request Forgery) guard shared by URL→PDF (§T-077)
  and any other call site that fetches remote resources.

  Blocks RFC1918, link-local, loopback, and cloud metadata IPs.
  Used by `ConvertWorker` to validate URLs before handing them to
  chromic_pdf.
  """

  @doc """
  Validates that `uri` (a `URI.t()` or string) does not point to a
  private, loopback, link-local, or cloud-metadata address.

  Returns `:ok` or `{:error, plain_language_message}`.
  """
  @spec check(URI.t() | String.t()) :: :ok | {:error, String.t()}
  def check(%URI{} = uri) do
    with :ok <- check_scheme(uri),
         :ok <- check_host(uri) do
      :ok
    end
  end

  def check(uri_string) when is_binary(uri_string) do
    case URI.parse(uri_string) do
      %URI{scheme: nil} -> {:error, "URL is missing a scheme"}
      %URI{} = uri -> check(uri)
    end
  rescue
    _ -> {:error, "Could not parse URL"}
  end

  # ── Scheme checks ────────────────────────────────────────────────────────

  @allowed_schemes ~w(http https)
  @external_resource_schemes ~w(file ftp gopher)

  defp check_scheme(%URI{scheme: scheme}) when scheme in @allowed_schemes, do: :ok

  defp check_scheme(%URI{scheme: scheme}) when scheme in @external_resource_schemes,
    do: {:error, "Scheme '#{scheme}' is not allowed — only HTTP(S) URLs are accepted"}

  defp check_scheme(%URI{scheme: nil}), do: {:error, "URL is missing a scheme"}

  defp check_scheme(%URI{scheme: scheme}),
    do: {:error, "Scheme '#{scheme}' is not allowed — only HTTP(S) URLs are accepted"}

  # ── Host checks ───────────────────────────────────────────────────────────

  defp check_host(%URI{host: nil}), do: {:error, "URL has no host"}
  defp check_host(%URI{host: host}), do: check_ip(host)

  defp check_ip(host) do
    cond do
      # Loopback — 127.0.0.0/8, ::1
      host in ~w(localhost 127.0.0.1 0.0.0.0 [::1] ::1) ->
        {:error, "Requests to localhost are not allowed"}

      # IPv4 dotted notation
      String.contains?(host, ".") and String.match?(host, ~r/^\d{1,3}(\.\d{1,3}){3}$/) ->
        check_ipv4(host)

      # IPv6 literal (bracketed or not)
      String.starts_with?(host, "[") || String.contains?(host, ":") ->
        check_ipv6(host)

      # Hostname — let DNS resolution happen at the caller if needed
      true ->
        :ok
    end
  end

  # ── IPv4 ──────────────────────────────────────────────────────────────────

  defp check_ipv4(ip) do
    octets =
      ip
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    case octets do
      [10 | _] ->
        {:error, "Requests to RFC1918 (10.0.0.0/8) addresses are not allowed"}

      [172, b | _] when b >= 16 and b <= 31 ->
        {:error, "Requests to RFC1918 (172.16.0.0/12) addresses are not allowed"}

      [192, 168 | _] ->
        {:error, "Requests to RFC1918 (192.168.0.0/16) addresses are not allowed"}

      [127 | _] ->
        {:error, "Requests to loopback addresses (127.0.0.0/8) are not allowed"}

      [169, 254 | _] ->
        {:error, "Requests to link-local addresses (169.254.0.0/16) are not allowed"}

      _ ->
        :ok
    end
  end

  # ── IPv6 ──────────────────────────────────────────────────────────────────

  # Simplified IPv6 private/loopback check — covers common cases.
  # Full subnet matching would require `:inet.parse_address/1` + bitwise ops.
  defp check_ipv6(ip) do
    cleaned = ip |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    cond do
      cleaned in ~w(0:0:0:0:0:0:0:1 ::1) ->
        {:error, "Requests to loopback (::1) are not allowed"}

      String.starts_with?(cleaned, "fc") or String.starts_with?(cleaned, "fd") ->
        {:error, "Requests to unique-local IPv6 (fc00::/7) addresses are not allowed"}

      String.starts_with?(cleaned, "fe80") ->
        {:error, "Requests to link-local IPv6 (fe80::/10) addresses are not allowed"}

      true ->
        :ok
    end
  end
end

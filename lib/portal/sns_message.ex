defmodule Portal.SnsMessage do
  @moduledoc """
  Signature verification for AWS SNS HTTP(S) messages.

  SNS signs every delivery (SignatureVersion 1 = SHA1-with-RSA, 2 =
  SHA256-with-RSA) over a canonical string of selected fields, and points
  at its X.509 signing certificate via `SigningCertURL`. We only trust a
  message after:

    1. the cert URL is HTTPS on an `sns.<region>.amazonaws.com` host
       (anything else could be an attacker's own cert),
    2. the RSA signature over the canonical string checks out against the
       cert's public key.

  The topic-ARN allow-list check lives in Portal.MailEventsController —
  this module is only about authenticity.

  Certificates are fetched once per URL and cached in `:persistent_term`
  (AWS rotates them rarely; a rotation simply introduces one new URL).
  Tests inject a `:signing_key_fetcher` (fn url -> {:ok, rsa_public_key})
  via the Portal.MailEvents config to avoid the network.
  """

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  @cert_host ~r/^sns\.[a-z0-9\-]+\.amazonaws\.com$/

  # Canonical-string fields per message type, in the exact order AWS
  # signs them (alphabetical; absent optional fields are skipped):
  # https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
  @notification_keys ~w(Message MessageId Subject SubscribeURL Timestamp Token TopicArn Type)
  @confirmation_keys @notification_keys

  def verify(%{"Signature" => sig, "SigningCertURL" => cert_url} = msg)
      when is_binary(sig) and is_binary(cert_url) do
    with {:ok, canonical} <- canonical_string(msg),
         {:ok, signature} <- Base.decode64(sig, ignore: :whitespace),
         :ok <- validate_aws_url(cert_url),
         {:ok, public_key} <- signing_key(cert_url),
         true <- :public_key.verify(canonical, digest_type(msg), signature, public_key) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  def verify(_msg), do: {:error, :bad_signature}

  @doc """
  The string SNS signed for `msg`. Public so tests can co-sign the same
  bytes with their own key.
  """
  def canonical_string(%{"Type" => type} = msg) when is_binary(type) do
    if type in ["Notification", "SubscriptionConfirmation", "UnsubscribeConfirmation"] do
      keys = if type == "Notification", do: @notification_keys -- ~w(SubscribeURL Token), else: @confirmation_keys

      {:ok,
       keys
       |> Enum.filter(fn key -> is_binary(msg[key]) end)
       |> Enum.map_join("", fn key -> "#{key}\n#{msg[key]}\n" end)}
    else
      {:error, :bad_type}
    end
  end

  def canonical_string(_msg), do: {:error, :bad_type}

  @doc "Enforce https + amazonaws SNS host on SigningCertURL/SubscribeURL."
  def validate_aws_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if Regex.match?(@cert_host, host), do: :ok, else: {:error, :bad_host}

      _ ->
        {:error, :bad_url}
    end
  end

  def validate_aws_url(_), do: {:error, :bad_url}

  defp digest_type(%{"SignatureVersion" => "2"}), do: :sha256
  defp digest_type(_msg), do: :sha

  defp signing_key(cert_url) do
    case Application.get_env(:rc, Portal.MailEvents, []) |> Keyword.get(:signing_key_fetcher) do
      nil -> cached_key(cert_url)
      fetcher -> fetcher.(cert_url)
    end
  end

  defp cached_key(cert_url) do
    case :persistent_term.get({__MODULE__, cert_url}, nil) do
      nil ->
        with {:ok, key} <- fetch_key(cert_url) do
          :persistent_term.put({__MODULE__, cert_url}, key)
          {:ok, key}
        end

      key ->
        {:ok, key}
    end
  end

  defp fetch_key(cert_url) do
    case :hackney.request(:get, cert_url, [], "", [:with_body]) do
      {:ok, 200, _headers, pem} -> public_key_from_pem(pem)
      _ -> {:error, :cert_fetch_failed}
    end
  end

  defp public_key_from_pem(pem) do
    with [{:Certificate, der, :not_encrypted} | _] <- :public_key.pem_decode(pem),
         otp_certificate(tbsCertificate: tbs) <- :public_key.pkix_decode_cert(der, :otp),
         otp_tbs_certificate(subjectPublicKeyInfo: spki) <- tbs,
         otp_subject_public_key_info(subjectPublicKey: public_key) <- spki do
      {:ok, public_key}
    else
      _ -> {:error, :bad_cert}
    end
  end
end

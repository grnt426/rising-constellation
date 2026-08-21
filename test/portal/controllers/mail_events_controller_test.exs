defmodule Portal.MailEventsControllerTest do
  # async: false — mutates the global Portal.MailEvents config.
  use Portal.APIConnCase, async: false

  import RC.Fixtures

  alias RC.Accounts.Account
  alias RC.Repo

  @topic "arn:aws:sns:us-east-1:123456789012:rc-mail-events"
  @cert_url "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem"

  # One RSA keypair for the whole module — 2048-bit generation is not free.
  setup_all do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    # :RSAPrivateKey record: modulus is element 3, publicExponent element 4.
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    %{private_key: private_key, public_key: public_key}
  end

  setup %{conn: conn, public_key: public_key} do
    previous = Application.get_env(:rc, Portal.MailEvents)

    Application.put_env(:rc, Portal.MailEvents,
      topic_arn: @topic,
      signing_key_fetcher: fn _url -> {:ok, public_key} end,
      subscribe_confirmer: fn url -> send(self(), {:confirmed, url}) end
    )

    on_exit(fn -> Application.put_env(:rc, Portal.MailEvents, previous) end)

    # SNS posts its JSON as text/plain
    {:ok, conn: put_req_header(conn, "content-type", "text/plain")}
  end

  defp sign(msg, private_key) do
    {:ok, canonical} = Portal.SnsMessage.canonical_string(msg)
    Map.put(msg, "Signature", Base.encode64(:public_key.sign(canonical, :sha, private_key)))
  end

  defp notification(event, private_key) do
    %{
      "Type" => "Notification",
      "MessageId" => "mid-#{System.unique_integer([:positive])}",
      "TopicArn" => @topic,
      "Message" => Jason.encode!(event),
      "Timestamp" => "2026-08-20T12:00:00.000Z",
      "SignatureVersion" => "1",
      "SigningCertURL" => @cert_url
    }
    |> sign(private_key)
  end

  defp hard_bounce(email) do
    %{
      "notificationType" => "Bounce",
      "bounce" => %{
        "bounceType" => "Permanent",
        "bouncedRecipients" => [%{"emailAddress" => email}]
      }
    }
  end

  test "a hard bounce stamps the account as undeliverable", %{conn: conn, private_key: key} do
    {:ok, account: account} = create_account_user_registered(%{})
    refute account.email_delivery_failed_at

    conn = post(conn, "/api/mail/events", Jason.encode!(notification(hard_bounce(account.email), key)))

    assert json_response(conn, 200)
    assert Repo.get(Account, account.id).email_delivery_failed_at
  end

  test "a transient bounce does not stamp", %{conn: conn, private_key: key} do
    {:ok, account: account} = create_account_user_registered(%{})

    event = %{
      "notificationType" => "Bounce",
      "bounce" => %{
        "bounceType" => "Transient",
        "bouncedRecipients" => [%{"emailAddress" => account.email}]
      }
    }

    conn = post(conn, "/api/mail/events", Jason.encode!(notification(event, key)))

    assert json_response(conn, 200)
    refute Repo.get(Account, account.id).email_delivery_failed_at
  end

  test "configuration-set eventType shape works too", %{conn: conn, private_key: key} do
    {:ok, account: account} = create_account_user_registered(%{})

    event = %{
      "eventType" => "Bounce",
      "bounce" => %{
        "bounceType" => "Permanent",
        "bouncedRecipients" => [%{"emailAddress" => account.email}]
      }
    }

    conn = post(conn, "/api/mail/events", Jason.encode!(notification(event, key)))

    assert json_response(conn, 200)
    assert Repo.get(Account, account.id).email_delivery_failed_at
  end

  test "a tampered message is rejected", %{conn: conn, private_key: key} do
    {:ok, account: account} = create_account_user_registered(%{})

    msg =
      notification(hard_bounce(account.email), key)
      |> Map.put("Message", Jason.encode!(hard_bounce("other@victim")))

    conn = post(conn, "/api/mail/events", Jason.encode!(msg))

    assert json_response(conn, 403)["message"] == "rejected"
    refute Repo.get(Account, account.id).email_delivery_failed_at
  end

  test "a message for another topic is rejected", %{conn: conn, private_key: key} do
    msg =
      %{
        "Type" => "Notification",
        "MessageId" => "mid",
        "TopicArn" => "arn:aws:sns:us-east-1:999:not-our-topic",
        "Message" => Jason.encode!(hard_bounce("x@y")),
        "Timestamp" => "2026-08-20T12:00:00.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => @cert_url
      }
      |> sign(key)

    conn = post(conn, "/api/mail/events", Jason.encode!(msg))

    assert json_response(conn, 403)["message"] == "rejected"
  end

  test "a non-AWS SigningCertURL is rejected", %{conn: conn, private_key: key} do
    msg =
      notification(hard_bounce("x@y"), key)
      |> Map.put("SigningCertURL", "https://evil.example.com/cert.pem")
      |> sign(key)

    conn = post(conn, "/api/mail/events", Jason.encode!(msg))

    assert json_response(conn, 403)["message"] == "rejected"
  end

  test "subscription confirmations are verified then confirmed via SubscribeURL", %{
    conn: conn,
    private_key: key
  } do
    url = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=abc"

    msg =
      %{
        "Type" => "SubscriptionConfirmation",
        "MessageId" => "mid",
        "Token" => "abc",
        "TopicArn" => @topic,
        "Message" => "You have chosen to subscribe...",
        "SubscribeURL" => url,
        "Timestamp" => "2026-08-20T12:00:00.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => @cert_url
      }
      |> sign(key)

    conn = post(conn, "/api/mail/events", Jason.encode!(msg))

    assert json_response(conn, 200)
    assert_received {:confirmed, ^url}
  end

  test "a subscription confirmation pointing off-AWS is not followed", %{conn: conn, private_key: key} do
    msg =
      %{
        "Type" => "SubscriptionConfirmation",
        "MessageId" => "mid",
        "Token" => "abc",
        "TopicArn" => @topic,
        "Message" => "You have chosen to subscribe...",
        "SubscribeURL" => "https://evil.example.com/steal",
        "Timestamp" => "2026-08-20T12:00:00.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => @cert_url
      }
      |> sign(key)

    conn = post(conn, "/api/mail/events", Jason.encode!(msg))

    # Message is authentic (200) but the URL fails the AWS-host check.
    assert json_response(conn, 200)
    refute_received {:confirmed, _}
  end

  test "the endpoint fails closed when no topic is configured", %{conn: conn, private_key: key} do
    Application.put_env(:rc, Portal.MailEvents, topic_arn: nil)

    conn = post(conn, "/api/mail/events", Jason.encode!(notification(hard_bounce("x@y"), key)))

    assert json_response(conn, 503)["message"] == "not_configured"
  end
end

defmodule Portal.MailEventsController do
  @moduledoc """
  SES bounce/complaint intake.

      POST /api/mail/events

  The SES configuration set (rc-transactional) publishes delivery events to
  the SNS topic rc-mail-events; an HTTPS subscription of that topic points
  here. Every post must (1) name the configured topic ARN and (2) carry a
  valid SNS signature (Portal.SnsMessage) before anything is trusted.

  * `SubscriptionConfirmation` — we GET the SubscribeURL (after the same
    signature + AWS-host checks), completing the handshake with no manual
    console step.
  * `Notification` with a Permanent bounce — stamps
    `email_delivery_failed_at` on the affected account(s); the portal's
    verify-email banner switches from "resend" to "sign up again with a
    working address" (the unverified-expiry sweep frees the dead account).
  * Complaints and everything else are logged only — SES account-level
    suppression already stops future sends to those addresses.

  This endpoint replaces the operator's inbox as the bounce consumer: once
  the subscription is live, the SNS→email subscription can be dropped so
  bounce storms never land in a human mailbox.

  SNS posts its JSON with `Content-Type: text/plain`, which our
  Plug.Parsers passes through unparsed — hence the manual read_body.
  """
  use Portal, :controller

  require Logger

  def create(conn, _params) do
    topic_arn = config(:topic_arn)

    with {:configured, true} <- {:configured, is_binary(topic_arn)},
         {:ok, msg} <- read_message(conn),
         {:topic, ^topic_arn} <- {:topic, msg["TopicArn"]},
         :ok <- Portal.SnsMessage.verify(msg) do
      handle_message(msg)
      json(conn, %{message: :ok})
    else
      {:configured, false} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{message: :not_configured})

      reason ->
        Logger.warning("rejected mail event post: #{inspect(reason)}")

        conn
        |> put_status(:forbidden)
        |> json(%{message: :rejected})
    end
  end

  # SNS delivers as text/plain (raw body available); a manual curl or a
  # replayed message may arrive as application/json (already parsed).
  defp read_message(conn) do
    with {:ok, body, _conn} when byte_size(body) > 0 <- Plug.Conn.read_body(conn),
         {:ok, msg} when is_map(msg) <- Jason.decode(body) do
      {:ok, msg}
    else
      _ ->
        case conn.body_params do
          %{"Type" => _} = msg -> {:ok, msg}
          _ -> {:error, :unreadable_body}
        end
    end
  end

  defp handle_message(%{"Type" => "SubscriptionConfirmation", "SubscribeURL" => url}) do
    case Portal.SnsMessage.validate_aws_url(url) do
      :ok ->
        Logger.info("confirming SNS mail-events subscription")
        confirm_subscription(url)

      error ->
        Logger.warning("refused SNS subscribe URL: #{inspect(error)}")
    end
  end

  defp handle_message(%{"Type" => "Notification", "Message" => message}) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, event} when is_map(event) -> handle_mail_event(event)
      _ -> Logger.warning("unparseable SES event payload")
    end
  end

  defp handle_message(%{"Type" => type}), do: Logger.info("ignored SNS message type #{inspect(type)}")

  # Identity-level feedback uses "notificationType"; configuration-set
  # event publishing uses "eventType". Same shapes underneath.
  defp handle_mail_event(%{"notificationType" => type} = event), do: dispatch_event(type, event)
  defp handle_mail_event(%{"eventType" => type} = event), do: dispatch_event(type, event)
  defp handle_mail_event(_event), do: Logger.info("ignored untyped SES event")

  defp dispatch_event("Bounce", event) do
    bounce = event["bounce"] || %{}
    recipients = for r <- bounce["bouncedRecipients"] || [], is_binary(r["emailAddress"]), do: r["emailAddress"]

    if bounce["bounceType"] == "Permanent" do
      Enum.each(recipients, fn email ->
        {count, _} = RC.Accounts.mark_email_delivery_failed(email)
        Logger.warning("SES hard bounce for #{email} (#{count} account(s) stamped)")
      end)
    else
      Logger.info("SES transient bounce (#{bounce["bounceType"]}) for #{inspect(recipients)}")
    end
  end

  defp dispatch_event("Complaint", event) do
    recipients =
      for r <- get_in(event, ["complaint", "complainedRecipients"]) || [],
          is_binary(r["emailAddress"]),
          do: r["emailAddress"]

    Logger.warning("SES complaint from #{inspect(recipients)}")
  end

  defp dispatch_event(type, _event), do: Logger.info("ignored SES event type #{inspect(type)}")

  defp confirm_subscription(url) do
    case config(:subscribe_confirmer) do
      nil ->
        case :hackney.request(:get, url, [], "", [:with_body]) do
          {:ok, 200, _headers, _body} -> Logger.info("SNS subscription confirmed")
          other -> Logger.error("SNS subscription confirmation failed: #{inspect(other)}")
        end

      confirmer ->
        confirmer.(url)
    end
  end

  defp config(key), do: Application.get_env(:rc, Portal.MailEvents, []) |> Keyword.get(key)
end

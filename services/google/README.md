# Google Workspace

Use the saved Google connection with `ryra integrations run` and an ordinary
HTTP client. Run these commands on the agent's machine, where `ryra`, `curl` and
an unlocked Ryra account with access to the connection's vault are available.
Installing the package or signing into Google in a browser does not provide
that access by itself.

Replace `ORG` and `EMAIL` with the intended organization and saved account:

```sh
ryra integrations ls --org ORG
```

Reuse an existing account with the required permissions. For a new connection
that only reads Gmail:

```sh
ryra integrations connect google --org ORG \
  --permission drive=off --permission gmail=read --permission calendar=off
```

Open the printed sign-in link in Ryra so browser approval returns to the machine
running the command. If login fails, report the error before starting another
attempt. For an existing account, use `--account EMAIL` and specify only the
permissions being changed.

Verify Gmail access before reporting it connected:

```sh
ryra integrations run google --org ORG --account EMAIL -- sh -c \
  'curl --fail --silent --show-error -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" \
    https://gmail.googleapis.com/gmail/v1/users/me/profile'
```

The [profile response](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/getProfile)
must succeed and identify the intended mailbox. Ryra refreshes credentials before
starting each command and gives the child an access token, not the refresh token.
Keep the single quotes so expansion happens inside that child. Never print the
token, enable shell tracing or copy credentials into chat.

Search mail, then read a returned message ID:

```sh
ryra integrations run google --org ORG --account EMAIL -- sh -c \
  'curl --fail --silent --show-error -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" \
    --get --data-urlencode "q=in:inbox" --data-urlencode "maxResults=10" \
    https://gmail.googleapis.com/gmail/v1/users/me/messages'

ryra integrations run google --org ORG --account EMAIL -- sh -c \
  'curl --fail --silent --show-error -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" \
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/MESSAGE_ID?format=full"'
```

[Search](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list)
returns IDs, not message bodies. Replace `MESSAGE_ID` with one returned by Google;
use [`messages.get`](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get)
to retrieve its content. Use `pageToken` with the returned `nextPageToken` when
more results are needed, keeping the same search.

Read access does not allow changes. Request `--permission gmail=write` only when
needed; before sending mail, show the recipients and final message and obtain
explicit user confirmation. Calendar and Drive have separate permission choices
shown by `integrations ls`.

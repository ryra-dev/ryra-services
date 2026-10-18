# X

Search and read public posts with an app-only bearer token from the
[X developer console](https://console.x.com). Create a developer app, copy its
Bearer Token from Keys and tokens, and configure API credits and a spending
limit. [API reads are billed](https://docs.x.com/x-api/getting-started/pricing).
Personal timelines, bookmarks and posting require a separate user OAuth flow.

Replace `ORG` with the intended organization. Check for a saved connection with
`ryra integrations ls x --org ORG`. Supply the credential through Ryra's private
credential form, or pipe a JSON object with the single `bearer_token` field from
a secret manager into:

```sh
ryra integrations connect x --org ORG --from-stdin
```

New connections are private; use `--vault VAULT` to explicitly share one.
Saving a token does not verify API access. Run a small search before reporting
it connected:

```sh
ryra integrations run x --org ORG -- sh -c \
  'printf "Authorization: Bearer %s\n" "$X_BEARER_TOKEN" | \
    curl --fail-with-body --silent --show-error -H @- \
    --get --data-urlencode "query=from:XDevelopers -is:retweet" \
    --data-urlencode "sort_order=recency" --data-urlencode "max_results=10" \
    --data-urlencode "tweet.fields=created_at,author_id,conversation_id,public_metrics" \
    https://api.x.com/2/tweets/search/recent'
```

`X_BEARER_TOKEN` is a child-process environment variable. The HTTP header is
`Authorization: Bearer ...`. Keep the shell's single quotes so the token expands
inside the child. The shell builtin `printf` passes the header through stdin,
keeping the token out of curl's process arguments. Keep credentials out of logs
and shell tracing.

[Recent search](https://docs.x.com/x-api/posts/search/quickstart/recent-search)
covers seven days. Replace the query with keywords, hashtags or `from:HANDLE`.
For another page, pass the returned `meta.next_token` as `next_token` with the
same query; for later checks, use `since_id` to request only newer posts.
Returned posts consume API credits. An empty successful result is valid.
Inspect response errors, including partial errors in a 200 response, before
retrying. Check credentials, credits, endpoint permissions and rate limits.

Read a returned post by replacing `POST_ID`:

```sh
ryra integrations run x --org ORG -- sh -c \
  'printf "Authorization: Bearer %s\n" "$X_BEARER_TOKEN" | \
    curl --fail-with-body --silent --show-error -H @- \
    "https://api.x.com/2/tweets/POST_ID?tweet.fields=created_at,author_id,conversation_id,public_metrics"'
```

X also provides an [official MCP endpoint](https://docs.x.com/tools/mcp) at
`https://api.x.com/mcp` accepting the same app-only bearer header for public read
tools. This service supplies credentials; configure an agent's MCP client
separately if needed.

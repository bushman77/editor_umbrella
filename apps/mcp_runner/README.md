# Editor.Umbrella local MCP runner (initial implementation)

This is a separate Elixir umbrella application so existing uncommitted changes in
`apps/llm`, `apps/editor`, and `apps/editor_web` are not overwritten.

It uses the Anubis MCP **STDIO transport**. There is no HTTP listener, tunnel,
or remote access. It runs on the laptop with the current Linux user's permissions.
It does not, by itself, make the server accessible from a ChatGPT Plus conversation.

## Tools

- `editor_read_file`: read up to 64 KiB of UTF-8 from an existing file in the configured workspace
- `editor_list_files`: list immediate children of a workspace directory
- `editor_git_status`: branch and working tree status
- `mix_compile`: compile a Mix project (explicit local opt-in required)
- `mix_test`: run all tests or one relative `*_test.exs` file (explicit local opt-in required)

There is **no arbitrary shell tool**, no writes, no `sudo`, no Git commits, and
no dependency installation tool. Paths must be relative, under one configured
workspace root; symbolic links in the path are rejected. Common credential
names, generated directories, and dependencies are excluded. Avoid including
secrets in files made accessible to any AI client.

## Install and test locally

From the existing clone (on `mcp_local_runner`), after applying the patch:

```bash
cd ~/editor_umbrella/apps/mcp_runner
mix deps.get
mix compile
mix test
```

`mix deps.get` updates the umbrella's existing `mix.lock` and may report
transitive dependency conflicts. Do not discard the existing lockfile to fix
those conflicts; inspect the solver output and resolve them specifically.

## Start the local MCP process

Choose exactly one project workspace. For example:

```bash
cd ~/editor_umbrella/apps/mcp_runner
EDITOR_MCP_ENABLED=1 \
EDITOR_MCP_WORKSPACE_ROOT="$HOME/editor_umbrella" \
mix run --no-halt
```

The terminal will appear idle because it is waiting for newline-delimited MCP
requests on standard input. For a different project, set `EDITOR_MCP_WORKSPACE_ROOT`
to that project's absolute path before launching.

To allow compile and tests, **explicitly** add:

```bash
EDITOR_MCP_ALLOW_EXECUTION=1
```

This authorization is decided at process start and is not accepted as an MCP
request argument. The development commands use the fixed executables `mix`
and GNU `timeout`, with per-command limits (60 seconds compile, 120 seconds tests).
No executable or shell string can be selected by the MCP client.

In a real MCP client configuration, launch this process as a STDIO command with
`cwd` set to `~/editor_umbrella/apps/mcp_runner` and the above environment.
Prepare dependencies and compile once before connecting. When
`EDITOR_MCP_ENABLED=1`, `config/runtime.exs` routes Logger output to stderr
so STDIO stdout stays reserved for MCP JSON-RPC. Any third-party library
that writes directly to stdout could still corrupt the stream.

## Remaining work

- Run the test suite and Anubis MCP handshake against this package on Pop!_OS.
- Ensure all application logging goes to stderr before using a long-lived client.
- Confirm any dependency solver conflicts with the existing uncommitted `mix.lock`.
- Review process-execution limits under larger `mix test` suites.
- Choose a permitted ChatGPT connection separately. This local server does not
  bypass ChatGPT plan-level restrictions.

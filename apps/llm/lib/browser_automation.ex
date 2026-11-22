defmodule Llm.BrowserAutomation do
  use GenServer

  import Wallaby.Browser, only: [visit: 2, current_url: 1]

  @call_timeout 60_000
  @script_timeout 5_000
  @chat_ready_timeout 30_000
  @chat_ready_poll_interval 500

  @venice_url "https://venice.ai/"
  @venice_chat_url "https://venice.ai/chat/agent"

  # Keep the persisted browser profile outside the application source tree.
  #
  # This is intentionally owned by the OS user, not by the umbrella app.
  # Chromium/Snap-style confinement failed against the old hidden
  # ~/.local/share/editor_umbrella/... path because it could not create
  # SingletonLock there.
  @venice_profile_dir "~/wallaby-venice-profile"

  # These are debug/snapshot locations only. Real Venice login persistence now
  # comes from the Chrome user-data-dir above.
  @profile_snapshot_dir "~/.local/share/editor_umbrella/wallaby/profile-snapshots"
  @session_snapshot_dir "~/.local/share/editor_umbrella/wallaby/session-snapshots"

  # Default stays false so non-dev/test environments do not unexpectedly launch
  # Chrome with a persisted personal browser profile. Enable this in dev config:
  #
  #     config :llm, Llm.BrowserAutomation, use_persistent_profile: true
  #
  @default_use_persistent_profile false

  @type result(value) :: {:ok, value} | {:error, term()}
  @type url_result :: result(%{url: String.t()})
  @type profile_status :: %{
          venice_url: String.t(),
          venice_chat_url: String.t(),
          venice_profile_dir: String.t(),
          persistent_profile?: boolean()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec open_venice() :: url_result()
  def open_venice do
    GenServer.call(__MODULE__, :open_venice, @call_timeout)
  end

  @spec open_chat() :: url_result()
  def open_chat do
    GenServer.call(__MODULE__, :open_chat, @call_timeout)
  end

  @spec wait_for_chat_ready() :: result(map())
  def wait_for_chat_ready do
    GenServer.call(__MODULE__, :wait_for_chat_ready, @call_timeout)
  end

  @spec current_url() :: result(String.t())
  def current_url do
    GenServer.call(__MODULE__, :current_url, @call_timeout)
  end

  @spec page_text() :: result(String.t())
  def page_text do
    GenServer.call(__MODULE__, :page_text, @call_timeout)
  end

  @spec page_snapshot() :: result(map())
  def page_snapshot do
    GenServer.call(__MODULE__, :page_snapshot, @call_timeout)
  end

  @spec inspect_chat_inputs() :: result(list())
  def inspect_chat_inputs do
    GenServer.call(__MODULE__, :inspect_chat_inputs, @call_timeout)
  end

  @spec send_prompt(String.t()) :: result(map())
  def send_prompt(prompt) when is_binary(prompt) do
    GenServer.call(__MODULE__, {:send_prompt, prompt}, @call_timeout)
  end

  @spec close() :: :ok
  def close do
    GenServer.call(__MODULE__, :close, @call_timeout)
  end

  @spec venice_profile_dir() :: String.t()
  def venice_profile_dir do
    Path.expand(@venice_profile_dir)
  end

  @spec profile_snapshot_dir() :: String.t()
  def profile_snapshot_dir do
    Path.expand(@profile_snapshot_dir)
  end

  @spec session_snapshot_dir() :: String.t()
  def session_snapshot_dir do
    Path.expand(@session_snapshot_dir)
  end

  @spec profile_status() :: profile_status()
  def profile_status do
    %{
      venice_url: @venice_url,
      venice_chat_url: @venice_chat_url,
      venice_profile_dir: venice_profile_dir(),
      persistent_profile?: use_persistent_profile?()
    }
  end

  # Backward-compatible name from the earlier snapshot experiment.
  #
  # Now that real Chrome profile persistence works, opening the chat directly is
  # the right behavior. The login is carried by the persisted Chrome profile.
  @spec open_venice_chat_with_latest_session() :: url_result()
  def open_venice_chat_with_latest_session do
    open_chat()
  end

  # ---------------------------------------------------------------------------
  # Debug/snapshot API
  # ---------------------------------------------------------------------------

  @spec snapshot_live_session() :: result(String.t())
  def snapshot_live_session do
    GenServer.call(__MODULE__, :snapshot_live_session, @call_timeout)
  end

  @spec restore_latest_live_session() :: url_result()
  def restore_latest_live_session do
    with {:ok, path} <- latest_live_session_snapshot() do
      restore_live_session(path)
    end
  end

  @spec restore_live_session(String.t()) :: url_result()
  def restore_live_session(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:restore_live_session, path}, @call_timeout)
  end

  @spec snapshot_profile() :: result(String.t())
  def snapshot_profile do
    profile_dir = ensure_venice_profile_dir!()
    snapshot_dir = ensure_profile_snapshot_dir!()

    snapshot_path =
      Path.join(snapshot_dir, "venice-profile-#{timestamp()}.tar.gz")

    create_profile_snapshot(profile_dir, snapshot_path)
  end

  @spec list_live_session_snapshots() :: [String.t()]
  def list_live_session_snapshots do
    session_snapshot_dir()
    |> Path.join("venice-live-session-*.etf")
    |> Path.wildcard()
    |> Enum.sort(:desc)
  end

  @spec latest_live_session_snapshot() :: result(String.t())
  def latest_live_session_snapshot do
    case list_live_session_snapshots() do
      [path | _rest] -> {:ok, path}
      [] -> {:error, :no_live_session_snapshots}
    end
  end

  @spec read_live_session_snapshot(String.t()) :: result(term())
  def read_live_session_snapshot(path) when is_binary(path) do
    with {:ok, data} <- File.read(path) do
      {:ok, :erlang.binary_to_term(data, [:safe])}
    end
  rescue
    error ->
      {:error, {:snapshot_read_failed, Exception.message(error)}}
  end

  @spec latest_live_session_summary() :: result(map())
  def latest_live_session_summary do
    with {:ok, path} <- latest_live_session_snapshot(),
         {:ok, snapshot} <- read_live_session_snapshot(path) do
      {:ok, live_session_summary(path, snapshot)}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{session: nil}}
  end

  @impl true
  def handle_call(:open_venice, _from, state) do
    case visit_url(state.session, @venice_url) do
      {:ok, session} ->
        reply_with_current_url(session, state)

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | session: nil}}
    end
  end

  def handle_call(:open_chat, _from, state) do
    case visit_url(state.session, @venice_chat_url) do
      {:ok, session} ->
        reply_with_current_url(session, state)

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | session: nil}}
    end
  end

  def handle_call(:wait_for_chat_ready, _from, state) do
    with {:ok, session} <- ensure_chat_session(state.session),
         {:ok, status} <- wait_for_chat_ready(session) do
      {:reply, {:ok, status}, %{state | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:current_url, _from, %{session: nil} = state) do
    {:reply, {:error, :no_browser_session}, state}
  end

  def handle_call(:current_url, _from, %{session: session} = state) do
    case safe_current_url(session) do
      {:ok, url} ->
        {:reply, {:ok, url}, state}

      {:error, reason} ->
        # Do not clear the session here.
        #
        # Wallaby can raise because of noisy third-party page logs or CORS console
        # errors. That does not always mean the Chrome session is actually dead.
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:page_text, _from, state) do
    with {:ok, session} <- ensure_chat_session(state.session),
         {:ok, _status} <- wait_for_chat_ready(session),
         {:ok, text} <- read_page_text(session) do
      {:reply, {:ok, text}, %{state | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:page_snapshot, _from, state) do
    with {:ok, session} <- ensure_chat_session(state.session),
         {:ok, snapshot} <- read_page_snapshot(session) do
      {:reply, {:ok, snapshot}, %{state | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:inspect_chat_inputs, _from, state) do
    with {:ok, session} <- ensure_chat_session(state.session),
         {:ok, _status} <- wait_for_chat_ready(session),
         {:ok, result} <- inspect_chat_input_candidates(session) do
      {:reply, {:ok, result}, %{state | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_prompt, prompt}, _from, state) do
    with {:ok, session} <- ensure_chat_session(state.session),
         {:ok, _status} <- wait_for_chat_ready(session),
         {:ok, result} <- send_prompt_to_chat(session, prompt) do
      {:reply, {:ok, result}, %{state | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot_live_session, _from, %{session: nil} = state) do
    {:reply, {:error, :no_browser_session}, state}
  end

  def handle_call(:snapshot_live_session, _from, %{session: session} = state) do
    case write_live_session_snapshot(session) do
      {:ok, path} ->
        {:reply, {:ok, path}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:restore_live_session, path}, _from, state) do
    case restore_live_session_from_disk(state.session, path) do
      {:ok, session} ->
        reply_with_current_url(session, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, %{session: session} = state) do
    safe_end_session(session)
    {:reply, :ok, %{state | session: nil}}
  end

  # ---------------------------------------------------------------------------
  # Browser/session lifecycle
  # ---------------------------------------------------------------------------

  defp ensure_chat_session(session) do
    ensure_url(session, @venice_chat_url)
  end

  defp ensure_url(nil, url) do
    visit_url(nil, url)
  end

  defp ensure_url(session, url) do
    case safe_current_url(session) do
      {:ok, current_url} when is_binary(current_url) ->
        if String.starts_with?(current_url, url) do
          {:ok, session}
        else
          visit_url(session, url)
        end

      {:error, _reason} ->
        visit_url(session, url)
    end
  end

  defp reply_with_current_url(session, state) do
    case safe_current_url(session) do
      {:ok, url} ->
        {:reply, {:ok, %{url: url}}, %{state | session: session}}

      {:error, reason} ->
        # Keep the session if navigation itself worked.
        # current_url/1 can fail from page JavaScript noise.
        {:reply, {:error, reason}, %{state | session: session}}
    end
  end

  defp visit_url(nil, url) do
    with {:ok, session} <- new_session(),
         {:ok, session} <- safe_visit(session, url) do
      {:ok, session}
    end
  end

  defp visit_url(session, url) do
    case safe_visit(session, url) do
      {:ok, session} ->
        {:ok, session}

      {:error, _reason} ->
        safe_end_session(session)
        retry_visit_with_fresh_session(url)
    end
  end

  defp retry_visit_with_fresh_session(url) do
    with {:ok, fresh_session} <- new_session(),
         {:ok, fresh_session} <- safe_visit(fresh_session, url) do
      {:ok, fresh_session}
    end
  end

  defp new_session do
    with :ok <- ensure_wallaby_started() do
      if use_persistent_profile?() do
        ensure_venice_profile_dir!()
      end

      Wallaby.start_session(
        capabilities: %{
          chromeOptions: %{
            args: chrome_args()
          }
        }
      )
    end
  end

  defp ensure_wallaby_started do
    case Application.ensure_all_started(:wallaby) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:wallaby_start_failed, reason}}
    end
  end

  defp safe_visit(session, url) do
    {:ok, visit(session, url)}
  rescue
    error ->
      {:error, {:visit_failed, Exception.message(error)}}
  end

  defp safe_current_url(session) do
    {:ok, current_url(session)}
  rescue
    error ->
      {:error, {:current_url_failed, Exception.message(error)}}
  end

  defp safe_end_session(nil), do: :ok

  defp safe_end_session(session) do
    Wallaby.end_session(session)
  rescue
    _error ->
      :ok
  end

  # ---------------------------------------------------------------------------
  # Chrome config
  # ---------------------------------------------------------------------------

  defp chrome_args do
    base_args = [
      "--window-size=1280,900",
      "--no-first-run",
      "--no-default-browser-check",
      "--remote-debugging-port=0",
      "--disable-dev-shm-usage"
    ]

    if use_persistent_profile?() do
      ["--user-data-dir=#{venice_profile_dir()}" | base_args]
    else
      base_args
    end
  end

  defp use_persistent_profile? do
    :llm
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:use_persistent_profile, @default_use_persistent_profile)
  end

  # ---------------------------------------------------------------------------
  # Page readiness / diagnostics
  # ---------------------------------------------------------------------------

  defp wait_for_chat_ready(session) do
    wait_for_chat_ready(session, System.monotonic_time(:millisecond), @chat_ready_timeout)
  end

  defp wait_for_chat_ready(session, started_at, timeout_ms) do
    case chat_ready_status(session) do
      {:ok, %{"ready" => true} = status} ->
        {:ok, status}

      {:ok, status} ->
        now = System.monotonic_time(:millisecond)

        if now - started_at >= timeout_ms do
          {:error, {:chat_ready_timeout, status}}
        else
          Process.sleep(@chat_ready_poll_interval)
          wait_for_chat_ready(session, started_at, timeout_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chat_ready_status(session) do
    script = """
    const editorSelectors = [
      "textarea",
      "input[type=text]",
      "input:not([type])",
      "[contenteditable=true]",
      "[contenteditable='']",
      "[contenteditable=plaintext-only]",
      "[role=textbox]"
    ];

    const buttonSelectors = [
      "button",
      "[role=button]"
    ];

    function visible(el) {
      return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
    }

    const editors = Array.from(document.querySelectorAll(editorSelectors.join(",")))
      .filter(visible);

    const buttons = Array.from(document.querySelectorAll(buttonSelectors.join(",")))
      .filter(visible);

    const bodyText = document.body ? document.body.innerText || "" : "";
    const bodyHtml = document.body ? document.body.innerHTML || "" : "";
    const loader = document.querySelector("#pre-js-loader");

    return JSON.stringify({
      ready: editors.length > 0 || bodyText.length > 0,
      href: window.location.href,
      title: document.title,
      readyState: document.readyState,
      bodyTextLength: bodyText.length,
      bodyHtmlLength: bodyHtml.length,
      editorCount: editors.length,
      buttonCount: buttons.length,
      hasPreJsLoader: !!loader,
      preJsLoaderHidden: loader ? loader.hidden || loader.getAttribute("aria-hidden") : null,
      navigatorWebdriver: navigator.webdriver === true
    });
    """

    with {:ok, json} <- execute_script_result(session, script) do
      decode_json(json)
    end
  end

  defp read_page_snapshot(session) do
    script = """
    const body = document.body;
    const root = document.documentElement;

    const scripts = Array.from(document.querySelectorAll("script")).map((script) => ({
      src: script.src || null,
      type: script.type || null,
      async: script.async,
      defer: script.defer
    }));

    const iframes = Array.from(document.querySelectorAll("iframe")).map((iframe) => ({
      src: iframe.src || null,
      title: iframe.title || null,
      visible: !!(iframe.offsetWidth || iframe.offsetHeight || iframe.getClientRects().length)
    }));

    const roots = [
      "#__next",
      "#root",
      "main",
      "[data-reactroot]",
      "[data-nextjs-router]",
      "#pre-js-loader"
    ].map((selector) => {
      const el = document.querySelector(selector);

      return {
        selector,
        found: !!el,
        textLength: el ? (el.innerText || "").length : 0,
        htmlLength: el ? (el.innerHTML || "").length : 0,
        visible: el ? !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length) : false
      };
    });

    return JSON.stringify({
      href: window.location.href,
      title: document.title,
      readyState: document.readyState,
      userAgent: navigator.userAgent,
      navigatorWebdriver: navigator.webdriver === true,
      bodyTextLength: body ? (body.innerText || "").length : 0,
      bodyHtmlLength: body ? (body.innerHTML || "").length : 0,
      rootHtmlLength: root ? (root.outerHTML || "").length : 0,
      bodyTextPreview: body ? (body.innerText || "").slice(0, 500) : "",
      bodyHtmlPreview: body ? (body.innerHTML || "").slice(0, 1200) : "",
      iframeCount: iframes.length,
      iframes: iframes,
      scriptCount: scripts.length,
      scripts: scripts.slice(0, 80),
      roots: roots
    }, null, 2);
    """

    with {:ok, json} <- execute_script_result(session, script) do
      decode_json(json)
    end
  end

  # ---------------------------------------------------------------------------
  # Page interaction
  # ---------------------------------------------------------------------------

  defp read_page_text(session) do
    script = """
    return document.body ? document.body.innerText : "";
    """

    execute_script_result(session, script)
  end

  defp inspect_chat_input_candidates(session) do
    script = """
    const selectors = [
      "textarea",
      "input",
      "[contenteditable=true]",
      "[contenteditable='']",
      "[contenteditable=plaintext-only]",
      "[role=textbox]",
      "button",
      "[role=button]",
      "form"
    ];

    function visible(el) {
      return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
    }

    function describe(el, selector) {
      return {
        selector,
        tag: el.tagName,
        type: el.getAttribute("type"),
        role: el.getAttribute("role"),
        ariaLabel: el.getAttribute("aria-label"),
        placeholder: el.getAttribute("placeholder"),
        name: el.getAttribute("name"),
        id: el.id || null,
        className: typeof el.className === "string" ? el.className.slice(0, 240) : null,
        text: (el.innerText || el.value || "").slice(0, 240),
        visible: visible(el),
        disabled: !!el.disabled || el.getAttribute("aria-disabled") === "true"
      };
    }

    const out = [];

    for (const selector of selectors) {
      for (const el of document.querySelectorAll(selector)) {
        out.push(describe(el, selector));
      }
    }

    return JSON.stringify(out, null, 2);
    """

    with {:ok, json} <- execute_script_result(session, script) do
      decode_json(json)
    end
  end

  defp send_prompt_to_chat(session, prompt) do
    encoded_prompt = Jason.encode!(prompt)

    script = """
    const prompt = #{encoded_prompt};

    function visible(el) {
      return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
    }

    function disabled(el) {
      return !!el.disabled || el.getAttribute("aria-disabled") === "true";
    }

    function describe(el) {
      if (!el) return null;

      return {
        tag: el.tagName,
        type: el.getAttribute("type"),
        role: el.getAttribute("role"),
        ariaLabel: el.getAttribute("aria-label"),
        placeholder: el.getAttribute("placeholder"),
        name: el.getAttribute("name"),
        id: el.id || null,
        className: typeof el.className === "string" ? el.className.slice(0, 240) : null,
        text: (el.innerText || el.value || "").slice(0, 240)
      };
    }

    function scoreEditor(el) {
      const text = [
        el.getAttribute("aria-label"),
        el.getAttribute("placeholder"),
        el.getAttribute("role"),
        el.getAttribute("name"),
        el.id,
        typeof el.className === "string" ? el.className : ""
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();

      let score = 0;

      if (el.tagName === "TEXTAREA") score += 100;
      if (el.getAttribute("contenteditable") === "true") score += 80;
      if (el.getAttribute("contenteditable") === "") score += 80;
      if (el.getAttribute("contenteditable") === "plaintext-only") score += 80;
      if (el.getAttribute("role") === "textbox") score += 70;
      if (text.includes("message")) score += 30;
      if (text.includes("prompt")) score += 30;
      if (text.includes("chat")) score += 20;
      if (text.includes("ask")) score += 20;

      return score;
    }

    function setNativeValue(el, value) {
      const valueSetter = Object.getOwnPropertyDescriptor(el, "value")?.set;
      const proto = Object.getPrototypeOf(el);
      const protoValueSetter = Object.getOwnPropertyDescriptor(proto, "value")?.set;

      if (protoValueSetter && valueSetter !== protoValueSetter) {
        protoValueSetter.call(el, value);
      } else if (valueSetter) {
        valueSetter.call(el, value);
      } else {
        el.value = value;
      }
    }

    function setEditorValue(el, value) {
      el.focus();

      if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
        setNativeValue(el, value);
        el.dispatchEvent(new Event("input", {bubbles: true}));
        el.dispatchEvent(new Event("change", {bubbles: true}));
        return;
      }

      el.textContent = value;
      el.dispatchEvent(
        new InputEvent("input", {
          bubbles: true,
          cancelable: true,
          inputType: "insertText",
          data: value
        })
      );
      el.dispatchEvent(new Event("change", {bubbles: true}));
    }

    function scoreButton(el) {
      const text = [
        el.innerText,
        el.getAttribute("aria-label"),
        el.getAttribute("title"),
        el.getAttribute("type"),
        el.id,
        typeof el.className === "string" ? el.className : ""
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();

      let score = 0;

      if (el.tagName === "BUTTON") score += 20;
      if (el.getAttribute("type") === "submit") score += 80;
      if (text.includes("send")) score += 100;
      if (text.includes("submit")) score += 60;
      if (text.includes("arrow")) score += 20;

      return score;
    }

    const editors = Array.from(
      document.querySelectorAll(
        [
          "textarea",
          "input[type=text]",
          "input:not([type])",
          "[contenteditable=true]",
          "[contenteditable='']",
          "[contenteditable=plaintext-only]",
          "[role=textbox]"
        ].join(",")
      )
    )
      .filter((el) => visible(el) && !disabled(el))
      .map((el) => ({el, score: scoreEditor(el)}))
      .sort((a, b) => b.score - a.score);

    const editor = editors[0]?.el;

    if (!editor) {
      return JSON.stringify({
        ok: false,
        reason: "no_prompt_editor_found",
        editors: editors.map(({el, score}) => ({score, element: describe(el)}))
      });
    }

    setEditorValue(editor, prompt);

    const buttons = Array.from(document.querySelectorAll("button, [role=button]"))
      .filter((el) => visible(el) && !disabled(el))
      .map((el) => ({el, score: scoreButton(el)}))
      .filter(({score}) => score > 0)
      .sort((a, b) => b.score - a.score);

    const sendButton = buttons[0]?.el;

    if (sendButton) {
      sendButton.click();

      return JSON.stringify({
        ok: true,
        strategy: "button_click",
        editor: describe(editor),
        sendButton: describe(sendButton)
      });
    }

    const form = editor.closest("form");

    if (form && typeof form.requestSubmit === "function") {
      form.requestSubmit();

      return JSON.stringify({
        ok: true,
        strategy: "form_request_submit",
        editor: describe(editor),
        form: describe(form)
      });
    }

    return JSON.stringify({
      ok: false,
      reason: "prompt_set_but_no_send_button_found",
      editor: describe(editor),
      buttons: buttons.map(({el, score}) => ({score, element: describe(el)}))
    });
    """

    with {:ok, json} <- execute_script_result(session, script),
         {:ok, result} <- decode_json(json) do
      case result do
        %{"ok" => true} ->
          {:ok, result}

        %{"ok" => false, "reason" => reason} ->
          {:error, {:send_prompt_failed, reason, result}}

        other ->
          {:ok, other}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Live browser session snapshot
  # ---------------------------------------------------------------------------

  defp write_live_session_snapshot(session) do
    with {:ok, url} <- safe_current_url(session),
         {:ok, cookies} <- safe_cookies(session),
         {:ok, local_storage_json} <- safe_storage_json(session, "localStorage"),
         {:ok, session_storage_json} <- safe_storage_json(session, "sessionStorage") do
      snapshot = %{
        version: 1,
        kind: :venice_live_browser_session,
        captured_at: DateTime.utc_now(),
        url: url,
        cookies: normalize_cookies(cookies),
        local_storage_json: local_storage_json,
        session_storage_json: session_storage_json
      }

      persist_live_session_snapshot(snapshot)
    end
  end

  defp safe_cookies(session) do
    {:ok, Wallaby.Browser.cookies(session)}
  rescue
    error ->
      {:error, {:cookies_failed, Exception.message(error)}}
  end

  defp safe_storage_json(session, storage_name)
       when storage_name in ["localStorage", "sessionStorage"] do
    script = """
    const storage = window.#{storage_name};
    const out = {};

    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i);
      out[key] = storage.getItem(key);
    }

    return JSON.stringify(out);
    """

    execute_script_result(session, script)
  end

  defp normalize_cookies(cookies) when is_list(cookies) do
    Enum.map(cookies, &normalize_cookie/1)
  end

  defp normalize_cookies(cookies), do: cookies

  defp normalize_cookie(%_struct{} = cookie) do
    Map.from_struct(cookie)
  end

  defp normalize_cookie(cookie), do: cookie

  defp persist_live_session_snapshot(snapshot) do
    snapshot_dir = ensure_session_snapshot_dir!()

    path =
      Path.join(snapshot_dir, "venice-live-session-#{timestamp()}.etf")

    data = :erlang.term_to_binary(snapshot)

    with :ok <- File.write(path, data),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error, {:snapshot_write_failed, reason}}
    end
  end

  defp live_session_summary(path, snapshot) do
    local_storage =
      snapshot
      |> Map.get(:local_storage_json, "{}")
      |> decode_json_object()

    session_storage =
      snapshot
      |> Map.get(:session_storage_json, "{}")
      |> decode_json_object()

    cookies =
      snapshot
      |> Map.get(:cookies, [])

    %{
      path: path,
      kind: Map.get(snapshot, :kind),
      captured_at: Map.get(snapshot, :captured_at),
      url: Map.get(snapshot, :url),
      cookie_count: length(cookies),
      cookie_names: Enum.map(cookies, &cookie_value(&1, :name)),
      local_storage_keys: Map.keys(local_storage),
      session_storage_keys: Map.keys(session_storage)
    }
  end

  # ---------------------------------------------------------------------------
  # Live browser session restore
  # ---------------------------------------------------------------------------

  defp restore_live_session_from_disk(existing_session, path) do
    with {:ok, snapshot} <- read_live_session_snapshot(path),
         :ok <- validate_live_session_snapshot(snapshot),
         {:ok, session} <- ensure_session_on_venice(existing_session),
         {:ok, session} <- restore_cookies(session, Map.get(snapshot, :cookies, [])),
         {:ok, session} <-
           restore_storage_json(
             session,
             "localStorage",
             Map.get(snapshot, :local_storage_json, "{}")
           ),
         {:ok, session} <-
           restore_storage_json(
             session,
             "sessionStorage",
             Map.get(snapshot, :session_storage_json, "{}")
           ),
         {:ok, session} <- safe_visit(session, @venice_chat_url) do
      {:ok, session}
    end
  end

  defp validate_live_session_snapshot(%{kind: :venice_live_browser_session}), do: :ok
  defp validate_live_session_snapshot(_snapshot), do: {:error, :invalid_live_session_snapshot}

  defp ensure_session_on_venice(nil) do
    with {:ok, session} <- new_session(),
         {:ok, session} <- safe_visit(session, @venice_url) do
      {:ok, session}
    end
  end

  defp ensure_session_on_venice(session) do
    safe_visit(session, @venice_url)
  end

  defp restore_cookies(session, cookies) when is_list(cookies) do
    Enum.reduce_while(cookies, {:ok, session}, fn cookie, {:ok, session} ->
      case safe_set_cookie(session, cookie) do
        {:ok, session} -> {:cont, {:ok, session}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_cookies(session, _cookies), do: {:ok, session}

  defp safe_set_cookie(session, cookie) do
    cookie = cookie_map(cookie)

    name = cookie_value(cookie, :name)
    value = cookie_value(cookie, :value)

    cond do
      is_nil(name) or name == "" ->
        {:ok, session}

      is_nil(value) ->
        {:ok, session}

      true ->
        attrs = cookie_attrs(cookie)

        try do
          {:ok, Wallaby.Browser.set_cookie(session, name, value, attrs)}
        rescue
          _error ->
            safe_set_minimal_cookie(session, name, value)
        end
    end
  end

  defp safe_set_minimal_cookie(session, name, value) do
    try do
      {:ok, Wallaby.Browser.set_cookie(session, name, value)}
    rescue
      error ->
        {:error, {:set_cookie_failed, name, Exception.message(error)}}
    end
  end

  defp restore_storage_json(session, storage_name, storage_json)
       when storage_name in ["localStorage", "sessionStorage"] do
    storage_json =
      case storage_json do
        value when is_binary(value) -> value
        _other -> "{}"
      end

    encoded_json = Jason.encode!(storage_json)

    script = """
    const entries = JSON.parse(#{encoded_json});
    const storage = window.#{storage_name};

    storage.clear();

    for (const [key, value] of Object.entries(entries)) {
      storage.setItem(key, value);
    }

    return true;
    """

    case execute_script_result(session, script) do
      {:ok, _result} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Script/json helpers
  # ---------------------------------------------------------------------------

  defp execute_script_result(session, script) do
    caller = self()
    ref = make_ref()

    Wallaby.Browser.execute_script(session, script, [], fn result ->
      send(caller, {ref, result})
    end)

    receive do
      {^ref, result} ->
        {:ok, result}
    after
      @script_timeout ->
        {:error, :script_result_timeout}
    end
  rescue
    error ->
      {:error, {:script_failed, Exception.message(error)}}
  end

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:json_decode_failed, Exception.message(reason)}}
    end
  end

  defp decode_json(other), do: {:error, {:expected_json_string, other}}

  defp decode_json_object(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp decode_json_object(_other), do: %{}

  # ---------------------------------------------------------------------------
  # Cookie helpers
  # ---------------------------------------------------------------------------

  defp cookie_map(%_struct{} = cookie), do: Map.from_struct(cookie)
  defp cookie_map(cookie) when is_map(cookie), do: cookie
  defp cookie_map(_cookie), do: %{}

  defp cookie_value(cookie, key) do
    Map.get(cookie, key) ||
      Map.get(cookie, Atom.to_string(key)) ||
      Map.get(cookie, camelize_key(key))
  end

  defp camelize_key(:http_only), do: "httpOnly"
  defp camelize_key(:same_site), do: "sameSite"
  defp camelize_key(key), do: Atom.to_string(key)

  defp cookie_attrs(cookie) do
    [
      domain: cookie_value(cookie, :domain),
      path: cookie_value(cookie, :path),
      secure: cookie_value(cookie, :secure),
      httpOnly: cookie_value(cookie, :http_only),
      sameSite: cookie_value(cookie, :same_site),
      expiry: cookie_value(cookie, :expiry) || cookie_value(cookie, :expires)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # ---------------------------------------------------------------------------
  # Chrome profile snapshot
  # ---------------------------------------------------------------------------

  defp create_profile_snapshot(profile_dir, snapshot_path) do
    case System.cmd("tar", [
           "-czf",
           snapshot_path,
           "-C",
           Path.dirname(profile_dir),
           Path.basename(profile_dir)
         ]) do
      {_output, 0} ->
        File.chmod(snapshot_path, 0o600)
        {:ok, snapshot_path}

      {output, code} ->
        {:error, {:snapshot_failed, code, output}}
    end
  end

  # ---------------------------------------------------------------------------
  # Filesystem helpers
  # ---------------------------------------------------------------------------

  defp ensure_venice_profile_dir! do
    venice_profile_dir()
    |> ensure_private_dir!()
  end

  defp ensure_profile_snapshot_dir! do
    profile_snapshot_dir()
    |> ensure_private_dir!()
  end

  defp ensure_session_snapshot_dir! do
    session_snapshot_dir()
    |> ensure_private_dir!()
  end

  defp ensure_private_dir!(dir) do
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    dir
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end

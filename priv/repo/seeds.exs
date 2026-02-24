# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Autoforge.Repo.insert!(%Autoforge.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Autoforge.Accounts.{User, UserGroup}

require Ash.Query

case User |> Ash.Query.filter(email == "mylan@mylan.io") |> Ash.read_one!(authorize?: false) do
  nil ->
    User
    |> Ash.Changeset.for_create(
      :create_user,
      %{email: "mylan@mylan.io", name: "Mylan Connolly", timezone: "America/New_York"},
      authorize?: false
    )
    |> Ash.create!()

    IO.puts("Seeded user: Mylan Connolly <mylan@mylan.io>")

  _existing ->
    IO.puts("User mylan@mylan.io already exists, skipping.")
end

# User Groups
for name <- ["Administrators", "Developers", "Testers"] do
  case UserGroup |> Ash.Query.filter(name == ^name) |> Ash.read_one!(authorize?: false) do
    nil ->
      UserGroup
      |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
      |> Ash.create!()

      IO.puts("Seeded user group: #{name}")

    _existing ->
      IO.puts("User group #{name} already exists, skipping.")
  end
end

# ── Bots ──────────────────────────────────────────────────────────────────────

alias Autoforge.Accounts.LlmProviderKey
alias Autoforge.Ai.{Bot, BotTool, BotUserGroup, Tool, UserGroupTool}

provider_keys =
  LlmProviderKey
  |> Ash.Query.sort(provider: :asc)
  |> Ash.read!(authorize?: false)
  |> Map.new(&{&1.provider, &1})

anthropic_key = Map.get(provider_keys, :anthropic)
cerebras_key = Map.get(provider_keys, :cerebras)

if anthropic_key || cerebras_key do
  # Look up tools
  get_url =
    Tool |> Ash.Query.filter(name == "get_url") |> Ash.read_one!(authorize?: false)

  get_time =
    Tool |> Ash.Query.filter(name == "get_time") |> Ash.read_one!(authorize?: false)

  delegate_task =
    Tool |> Ash.Query.filter(name == "delegate_task") |> Ash.read_one!(authorize?: false)

  # Look up user groups
  admins =
    UserGroup |> Ash.Query.filter(name == "Administrators") |> Ash.read_one!(authorize?: false)

  devs =
    UserGroup |> Ash.Query.filter(name == "Developers") |> Ash.read_one!(authorize?: false)

  testers =
    UserGroup |> Ash.Query.filter(name == "Testers") |> Ash.read_one!(authorize?: false)

  # Anthropic models (deep reasoning, code review, architecture)
  opus_model = "anthropic:claude-opus-4-6"
  sonnet_model = "anthropic:claude-sonnet-4-6"

  # Cerebras models (fast domain knowledge recall)
  cerebras_coder = "cerebras:qwen-3-coder-480b"
  cerebras_instruct = "cerebras:qwen-3-235b-a22b-instruct-2507"

  bot_definitions = [
    %{
      name: "Elixir Architect",
      description:
        "Expert in OTP design, supervision trees, and distributed Elixir architecture.",
      model: opus_model,
      key: anthropic_key,
      temperature: 0.6,
      max_tokens: 4096,
      tools: [get_url, delegate_task],
      groups: [admins, devs],
      system_prompt: """
      You are the Elixir Architect, a senior systems designer specializing in Elixir and OTP.

      Your expertise covers:
      - OTP supervision trees and process architecture
      - GenServer, Agent, and Task patterns
      - Distributed Elixir with clustering and node communication
      - The "let it crash" philosophy and fault-tolerant design
      - Layered application architecture (context boundaries, domain separation)
      - Performance considerations for BEAM processes and schedulers

      When advising, always consider fault tolerance, scalability, and maintainability. Recommend supervision strategies, process boundaries, and message-passing patterns that align with OTP best practices. Provide concrete examples using Elixir syntax.
      """
    },
    %{
      name: "Ash Sage",
      description: "Deep knowledge of the Ash Framework DSL, resources, actions, and policies.",
      model: cerebras_instruct,
      key: cerebras_key,
      temperature: 0.5,
      max_tokens: 4096,
      tools: [get_url, delegate_task],
      groups: [admins, devs],
      system_prompt: """
      You are the Ash Sage, an expert in the Ash Framework for Elixir.

      Your expertise covers:
      - Ash DSL for defining resources, attributes, relationships, and identities
      - Actions (create, read, update, destroy) and custom actions
      - Policies and authorization rules
      - Changesets, validations, and calculations
      - AshPostgres data layer and migrations
      - AshAuthentication and AshGraphql extensions
      - Spark introspection and extension development
      - Domain design and resource organization

      Always recommend idiomatic Ash patterns. Prefer declarative DSL definitions over imperative code. Guide users toward proper use of actions, policies, and the resource lifecycle.
      """
    },
    %{
      name: "Phoenix Guide",
      description:
        "Phoenix 1.8 expert covering LiveView, layouts, components, and the asset pipeline.",
      model: cerebras_instruct,
      key: cerebras_key,
      temperature: 0.5,
      max_tokens: 4096,
      tools: [get_url, delegate_task],
      groups: [admins, devs],
      system_prompt: """
      You are the Phoenix Guide, an expert in the Phoenix Framework v1.8.

      Your expertise covers:
      - Phoenix 1.8 conventions and project structure
      - LiveView lifecycle (mount, handle_params, handle_event, handle_info)
      - Layouts.app wrapper pattern — always begin templates with <Layouts.app flash={@flash}>
      - Core components and the <.input>, <.icon>, <.button> component system
      - Fluxon UI components (prefer these over hand-written components)
      - Tailwind CSS v4 with the new @import syntax (no tailwind.config.js)
      - PubSub for real-time features
      - Asset pipeline (app.js and app.css bundles only, no inline scripts)
      - Router pipelines, live_session, and authentication scopes

      Follow Phoenix 1.8 conventions strictly. Never use <.flash_group> outside layouts. Never suggest inline script tags. Always recommend Fluxon components when available.
      """
    },
    %{
      name: "Code Crafter",
      description:
        "Writes production-quality Elixir, Ash, and Phoenix code with full documentation.",
      model: sonnet_model,
      key: anthropic_key,
      temperature: 0.3,
      max_tokens: 8192,
      tools: [get_url, get_time, delegate_task],
      groups: [admins, devs],
      system_prompt: """
      You are the Code Crafter, a production code generator for Elixir, Ash, and Phoenix projects.

      When writing code, always:
      - Include @moduledoc and @doc documentation for all public modules and functions
      - Add @spec type specifications for public functions
      - Use pattern matching in function heads over conditional logic
      - Leverage the pipe operator for data transformations
      - Follow Elixir naming conventions (snake_case functions, PascalCase modules)
      - Use Ash DSL for resource definitions, not raw Ecto schemas
      - Follow Phoenix 1.8 conventions for LiveView and component code
      - Write idiomatic, clean code that passes `mix format` and `mix credo`

      Output complete, working modules. Do not use placeholder comments or incomplete implementations. Every function should be fully realized and ready for production use.
      """
    },
    %{
      name: "Code Reviewer",
      description:
        "Reviews Elixir code across correctness, idioms, OTP, performance, and security.",
      model: opus_model,
      key: anthropic_key,
      temperature: 0.4,
      max_tokens: 4096,
      tools: [get_url, delegate_task],
      groups: [admins, devs],
      system_prompt: """
      You are the Code Reviewer, an expert at reviewing Elixir, Ash, and Phoenix code.

      Review code across these 8 dimensions:
      1. **Correctness** — Logic errors, edge cases, race conditions
      2. **Elixir Idioms** — Pattern matching, pipe operator, naming conventions, proper use of standard library
      3. **OTP Patterns** — GenServer design, supervision, process boundaries, fault tolerance
      4. **Performance** — Inefficient algorithms, N+1 queries, unnecessary process spawning, Stream vs Enum
      5. **Security** — Input validation, atom creation from user input, SQL injection, XSS
      6. **Ash Framework** — Proper DSL usage, action design, policy correctness, relationship patterns
      7. **Phoenix** — LiveView best practices, component design, layout conventions, PubSub usage
      8. **Testability** — Code structure that supports testing, missing test coverage areas

      Categorize each finding as:
      - **CRITICAL** — Must fix before merge (bugs, security issues)
      - **WARNING** — Should fix (performance, maintainability concerns)
      - **SUGGESTION** — Nice to have (idiom improvements, readability)
      - **NITPICK** — Minor style preferences

      Be thorough but constructive. Explain why each finding matters and provide a concrete fix.
      """
    },
    %{
      name: "Test Engineer",
      description:
        "Designs and writes ExUnit tests for Ash resources, LiveView, and property-based testing.",
      model: sonnet_model,
      key: anthropic_key,
      temperature: 0.3,
      max_tokens: 8192,
      tools: [get_time, delegate_task],
      groups: [admins, devs, testers],
      system_prompt: """
      You are the Test Engineer, an expert in testing Elixir, Ash, and Phoenix applications.

      Your expertise covers:
      - ExUnit test design and organization (describe blocks, setup, tags)
      - Ash resource testing (action testing, policy testing, validation testing)
      - Phoenix LiveView testing with live/2, render_click, render_submit
      - Property-based testing with StreamData
      - Mocking with Mox for behaviour-based testing
      - Req.Test for HTTP client testing
      - Oban.Testing for background job testing
      - Test factories and data generation
      - Integration vs unit test strategies

      When writing tests:
      - Use descriptive test names that explain the expected behavior
      - Follow arrange-act-assert structure
      - Test both happy paths and error cases
      - Use setup blocks to reduce duplication
      - Prefer testing through public interfaces over internal implementation details
      - Always include assertions — never write tests that only exercise code without verifying results
      """
    }
  ]

  for bot_def <- bot_definitions, bot_def.key != nil do
    bot =
      case Bot |> Ash.Query.filter(name == ^bot_def.name) |> Ash.read_one!(authorize?: false) do
        nil ->
          bot =
            Bot
            |> Ash.Changeset.for_create(
              :create,
              %{
                name: bot_def.name,
                description: bot_def.description,
                system_prompt: bot_def.system_prompt,
                model: bot_def.model,
                temperature: bot_def.temperature,
                max_tokens: bot_def.max_tokens,
                llm_provider_key_id: bot_def.key.id
              },
              authorize?: false
            )
            |> Ash.create!()

          IO.puts("Seeded bot: #{bot_def.name}")
          bot

        existing ->
          IO.puts("Bot #{bot_def.name} already exists, skipping.")
          existing
      end

    # Create BotTool joins
    for tool <- bot_def.tools, tool != nil do
      try do
        BotTool
        |> Ash.Changeset.for_create(
          :create,
          %{bot_id: bot.id, tool_id: tool.id},
          authorize?: false
        )
        |> Ash.create!()

        IO.puts("  Linked #{bot_def.name} -> tool #{tool.name}")
      rescue
        _ -> IO.puts("  Bot-tool link #{bot_def.name} -> #{tool.name} already exists, skipping.")
      end
    end

    # Create BotUserGroup joins
    for group <- bot_def.groups, group != nil do
      try do
        BotUserGroup
        |> Ash.Changeset.for_create(
          :create,
          %{bot_id: bot.id, user_group_id: group.id},
          authorize?: false
        )
        |> Ash.create!()

        IO.puts("  Linked #{bot_def.name} -> group #{group.name}")
      rescue
        _ ->
          IO.puts("  Bot-group link #{bot_def.name} -> #{group.name} already exists, skipping.")
      end
    end
  end

  # ── UserGroup-Tool assignments ──────────────────────────────────────────────

  user_group_tool_matrix = [
    {admins, [get_url, get_time, delegate_task]},
    {devs, [get_url, get_time, delegate_task]},
    {testers, [get_time, delegate_task]}
  ]

  for {group, tools} <- user_group_tool_matrix, group != nil do
    for tool <- tools, tool != nil do
      try do
        UserGroupTool
        |> Ash.Changeset.for_create(
          :create,
          %{user_group_id: group.id, tool_id: tool.id},
          authorize?: false
        )
        |> Ash.create!()

        IO.puts("Linked group #{group.name} -> tool #{tool.name}")
      rescue
        _ ->
          IO.puts("Group-tool link #{group.name} -> #{tool.name} already exists, skipping.")
      end
    end
  end
else
  IO.puts("No provider keys found, skipping bot seeding.")
end

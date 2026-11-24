package mcp

Catalog_Tool :: enum u8 {
	Spawn,
	Send,
	Wait,
	List,
	Cancel,
	Result,
	Merge,
	Memory_Search,
	Memory_Read,
	Memory_Write,
	Schedule,
	History_Search,
}

Catalog_Tools :: bit_set[Catalog_Tool;u16]

ALL_CATALOG_TOOLS :: Catalog_Tools{.Spawn, .Send, .Wait, .List, .Cancel, .Result, .Merge, .Memory_Search, .Memory_Read, .Memory_Write, .Schedule, .History_Search}

ORCHESTRATION_TOOLS :: Catalog_Tools{.Spawn, .Send, .Wait, .List, .Cancel, .Result, .Merge}

MEMORY_TOOLS :: Catalog_Tools{.Memory_Search, .Memory_Read, .Memory_Write}

Catalog_Entry :: struct {
	name:          string,
	title:         string,
	description:   string,
	input_schema:  string,
	output_schema: string,
	annotations:   string,
}

catalog_entry :: proc "contextless" (t: Catalog_Tool) -> Catalog_Entry {
	return CATALOG[t]
}

catalog_lookup :: proc "contextless" (name: string) -> (Catalog_Tool, bool) {
	for t in Catalog_Tool {
		if CATALOG[t].name == name {
			return t, true
		}
	}
	return .Spawn, false
}

catalog_register :: proc(s: ^Server, tools: Catalog_Tools, handler: Request_Handler, data: rawptr) -> bool {
	ok := true
	for t in Catalog_Tool {
		if t not_in tools {
			continue
		}
		e := CATALOG[t]
		ok &= server_add_tool(s, Tool_Def{name = e.name, title = e.title, description = e.description, input_schema = e.input_schema, output_schema = e.output_schema, annotations = e.annotations, handler = handler, data = data})
	}
	return ok
}

CATALOG_INSTRUCTIONS :: `0ndb records everything this session does and coordinates work across agents. Tasks are child conversations: spawn creates one with a goal, send writes into it, wait blocks until tasks settle (a durable wait that survives restarts), result reads a finished task, merge lands its file changes into yours, cancel stops a subtree. Memory tools read and write durable notes and facts shared with your other runs. history_search finds past conversations, messages and the code they wrote. Ids are 32-character lowercase hex strings.`

@(private, rodata)
CATALOG := [Catalog_Tool]Catalog_Entry {
	.Spawn = {
		name = "spawn",
		title = "Spawn task",
		description = "Start a child task: a new conversation whose parent is the current one, answered by an agent working toward the goal. File trees are forked from your current lines, so the child never touches your files until you merge it. Returns immediately with the task id; use wait to block on it.",
		input_schema = `{"type":"object","properties":{"goal":{"type":"string","minLength":1,"description":"What the task must accomplish; becomes the child's first message."},"title":{"type":"string","maxLength":200,"description":"Short display title. Defaults to a summary of the goal."},"agent":{"type":"string","minLength":1,"description":"Agent id or name that answers the task. Defaults to your own agent."},"provider":{"type":"string","minLength":1,"description":"Harness or model provider override, e.g. claude, codex, native."},"model":{"type":"string","minLength":1,"description":"Model override for the task's runs."},"workspace":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Workspace id. Defaults to the current conversation's workspace."},"mounts":{"type":"array","description":"File trees the task works on. Defaults to every tree mounted here, forked from your current lines.","items":{"type":"object","properties":{"name":{"type":"string","minLength":1,"description":"Mount name, as listed in the current conversation or workspace."},"tree":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"File tree id when mounting a tree that is not mounted here."},"path":{"type":"string","description":"Directory under the task's root where the tree is materialized."},"share":{"type":"boolean","default":false,"description":"Work on your line directly instead of a fork. Writes then land without merge."}},"required":["name"],"additionalProperties":false}},"budget":{"type":"object","description":"Limits for the task and its own subtasks; never more than your remaining budget.","properties":{"tokens":{"type":"integer","minimum":1},"usd":{"type":"number","exclusiveMinimum":0},"turns":{"type":"integer","minimum":1},"seconds":{"type":"integer","minimum":1}},"additionalProperties":false},"runner":{"type":"string","minLength":1,"description":"Runner placement policy or runner id, passed to the scheduler."},"isolate":{"type":"boolean","description":"true: the task works on forks of your lines and lands into them each time it completes a turn; overlapping edits stay in the fork as conflicts and the task is held until they are resolved. false: the task works on your lines directly. Defaults to the agent's isolate option."},"context":{"type":"string","description":"Extra context appended to the goal, e.g. constraints or relevant findings."}},"required":["goal"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"task":{"type":"string","pattern":"^[0-9a-f]{32}$"},"title":{"type":"string"},"status":{"type":"string","enum":["queued","running","waiting","completed","failed","cancelled"]}},"required":["task","status"]}`,
		annotations = `{"title":"Spawn task","readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}`,
	},
	.Send = {
		name = "send",
		title = "Send to task",
		description = "Write a message into a task or any conversation you may write to. queue delivers it after the current turn, steer injects it into the running turn, interrupt stops the running turn and then delivers it. The message is durable the moment this returns.",
		input_schema = `{"type":"object","properties":{"task":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Task or conversation id."},"message":{"type":"string","minLength":1,"description":"Message text."},"mode":{"type":"string","enum":["queue","steer","interrupt"],"default":"queue"}},"required":["task","message"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"task":{"type":"string"},"message":{"type":"string","description":"Id of the written record."},"status":{"type":"string"}},"required":["task","message"]}`,
		annotations = `{"title":"Send to task","readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}`,
	},
	.Wait = {
		name = "wait",
		title = "Wait for tasks",
		description = "Block until tasks settle. any returns when the first listed task reaches one of the statuses, all when every one has. Defaults to all of your direct children and the terminal statuses, including held (an isolated task whose land hit conflicts). The wait is recorded, so it resumes after a crash or on another runner. Returns each task's status and a result summary.",
		input_schema = `{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"string","pattern":"^[0-9a-f]{32}$"},"uniqueItems":true,"description":"Task ids. Defaults to every direct child of the current conversation."},"condition":{"type":"string","enum":["any","all"],"default":"all"},"statuses":{"type":"array","items":{"type":"string","enum":["waiting","completed","failed","cancelled","held"]},"uniqueItems":true,"minItems":1,"description":"Statuses that count as settled. Defaults to completed, failed, cancelled and held."},"timeout_seconds":{"type":"integer","minimum":0,"maximum":604800,"description":"Give up after this long and report current statuses. 0 checks without waiting. Omit to wait without limit."}},"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"satisfied":{"type":"boolean"},"timed_out":{"type":"boolean"},"tasks":{"type":"array","items":{"type":"object","properties":{"task":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"summary":{"type":"string"},"usage":{"type":"object"}},"required":["task","status"]}}},"required":["satisfied","tasks"]}`,
		annotations = `{"title":"Wait for tasks","readOnlyHint":true,"openWorldHint":false}`,
	},
	.List = {
		name = "list",
		title = "List tasks",
		description = "List tasks under a conversation (default: the current one) with status, title, activity and usage rolled up from their subtrees.",
		input_schema = `{"type":"object","properties":{"parent":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Parent conversation id. Defaults to the current conversation."},"recursive":{"type":"boolean","default":false,"description":"Include descendants, not only direct children."},"statuses":{"type":"array","items":{"type":"string","enum":["queued","running","waiting","completed","failed","cancelled","held"]},"uniqueItems":true},"limit":{"type":"integer","minimum":1,"maximum":500,"default":50},"cursor":{"type":"string","description":"Opaque cursor from a previous call."}},"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object","properties":{"task":{"type":"string"},"parent":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"agent":{"type":"string"},"updated":{"type":"string","format":"date-time"},"usage":{"type":"object"}},"required":["task","status"]}},"next_cursor":{"type":"string"}},"required":["tasks"]}`,
		annotations = `{"title":"List tasks","readOnlyHint":true,"openWorldHint":false}`,
	},
	.Cancel = {
		name = "cancel",
		title = "Cancel tasks",
		description = "Cancel tasks and, by default, every task below them. Running turns are interrupted; finished work and file lines are kept and can still be merged.",
		input_schema = `{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"string","pattern":"^[0-9a-f]{32}$"},"minItems":1,"uniqueItems":true},"reason":{"type":"string","maxLength":2000},"recursive":{"type":"boolean","default":true}},"required":["tasks"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"cancelled":{"type":"array","items":{"type":"string"}},"already_settled":{"type":"array","items":{"type":"string"}}},"required":["cancelled"]}`,
		annotations = `{"title":"Cancel tasks","readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,"openWorldHint":false}`,
	},
	.Result = {
		name = "result",
		title = "Task result",
		description = "Read what a task produced: its sealed final answer, status and usage, the files it changed per mount, and optionally its last messages.",
		input_schema = `{"type":"object","properties":{"task":{"type":"string","pattern":"^[0-9a-f]{32}$"},"messages":{"type":"integer","minimum":0,"maximum":100,"default":0,"description":"Also return this many of the task's most recent messages."},"diff":{"type":"boolean","default":false,"description":"Include a unified diff of the task's line against the point it forked from."},"max_chars":{"type":"integer","minimum":256,"maximum":1000000,"default":20000}},"required":["task"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"task":{"type":"string"},"status":{"type":"string"},"result":{"type":"string"},"files":{"type":"array","items":{"type":"object","properties":{"mount":{"type":"string"},"path":{"type":"string"},"change":{"type":"string","enum":["added","modified","deleted","renamed"]}},"required":["mount","path","change"]}},"diff":{"type":"string"},"messages":{"type":"array","items":{"type":"object","properties":{"role":{"type":"string"},"text":{"type":"string"}},"required":["role","text"]}},"usage":{"type":"object"},"land_conflicts":{"type":"array","items":{"type":"string"},"description":"Paths whose land into your lines hit overlapping edits. They carry conflict markers in the task's fork; the task stays held until they are resolved there."},"truncated":{"type":"boolean"}},"required":["task","status"]}`,
		annotations = `{"title":"Task result","readOnlyHint":true,"openWorldHint":false}`,
	},
	.Merge = {
		name = "merge",
		title = "Merge task",
		description = "Land a task's file changes into your lines, mount by mount. Concurrent overlapping edits are never auto-resolved: they are reported as conflicts and stored in the task's fork, and nothing lands until none remain. dry_run reports what would happen without landing.",
		input_schema = `{"type":"object","properties":{"task":{"type":"string","pattern":"^[0-9a-f]{32}$"},"mounts":{"type":"array","items":{"type":"string","minLength":1},"uniqueItems":true,"description":"Mount names to land. Defaults to every mount the task changed."},"dry_run":{"type":"boolean","default":false}},"required":["task"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"landed":{"type":"boolean"},"mounts":{"type":"array","items":{"type":"object","properties":{"mount":{"type":"string"},"landed":{"type":"boolean"},"files":{"type":"integer"},"conflicts":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"ours":{"type":"string"},"theirs":{"type":"string"},"lines":{"type":"string"}},"required":["path"]}}},"required":["mount","landed"]}}},"required":["landed","mounts"]}`,
		annotations = `{"title":"Merge task","readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}`,
	},
	.Memory_Search = {
		name = "memory_search",
		title = "Search memory",
		description = "Search durable memory (notes and facts this agent and its tasks wrote) by text or meaning.",
		input_schema = `{"type":"object","properties":{"query":{"type":"string","minLength":1},"mode":{"type":"string","enum":["text","semantic","hybrid"],"default":"hybrid"},"memory":{"type":"array","items":{"type":"string","pattern":"^[0-9a-f]{32}$"},"uniqueItems":true,"description":"Memory object ids to search. Defaults to the agent's memory."},"kind":{"type":"string","enum":["any","note","fact"],"default":"any"},"limit":{"type":"integer","minimum":1,"maximum":100,"default":10},"cursor":{"type":"string"}},"required":["query"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"hits":{"type":"array","items":{"type":"object","properties":{"memory":{"type":"string"},"kind":{"type":"string","enum":["note","fact"]},"key":{"type":"string"},"snippet":{"type":"string"},"score":{"type":"number"},"updated":{"type":"string","format":"date-time"}},"required":["memory","kind","key","snippet"]}},"next_cursor":{"type":"string"}},"required":["hits"]}`,
		annotations = `{"title":"Search memory","readOnlyHint":true,"openWorldHint":false}`,
	},
	.Memory_Read = {
		name = "memory_read",
		title = "Read memory",
		description = "Read a note (by key, optionally a line range) or a fact (by key), or list keys under a prefix when key ends with /.",
		input_schema = `{"type":"object","properties":{"key":{"type":"string","minLength":1,"description":"Note or fact key, e.g. projects/ondb/decisions. A trailing / lists keys under that prefix."},"memory":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Memory object id. Defaults to the agent's memory."},"kind":{"type":"string","enum":["any","note","fact"],"default":"any"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1}},"required":["key"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"key":{"type":"string"},"kind":{"type":"string","enum":["note","fact","prefix"]},"text":{"type":"string"},"value":{},"keys":{"type":"array","items":{"type":"string"}},"updated":{"type":"string","format":"date-time"},"author":{"type":"string"}},"required":["key","kind"]}`,
		annotations = `{"title":"Read memory","readOnlyHint":true,"openWorldHint":false}`,
	},
	.Memory_Write = {
		name = "memory_write",
		title = "Write memory",
		description = "Write durable memory. Notes are texts: set replaces, append adds to the end. Facts are keyed values with last-writer-wins merging across devices. delete removes the key; history keeps who wrote what.",
		input_schema = `{"type":"object","properties":{"key":{"type":"string","minLength":1,"maxLength":512},"kind":{"type":"string","enum":["note","fact"],"default":"note"},"op":{"type":"string","enum":["set","append","delete"],"default":"set"},"text":{"type":"string","description":"Note text for set and append."},"value":{"description":"Fact value for set: any JSON value."},"memory":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Memory object id. Defaults to the agent's memory."}},"required":["key"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"key":{"type":"string"},"kind":{"type":"string"},"op":{"type":"string"},"record":{"type":"string"}},"required":["key","kind","op"]}`,
		annotations = `{"title":"Write memory","readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}`,
	},
	.Schedule = {
		name = "schedule",
		title = "Schedule",
		description = "Create, list or remove durable schedules that start runs without anyone present. A schedule sends its prompt to a conversation (default: this one) on a cron expression or once at a time.",
		input_schema = `{"type":"object","properties":{"action":{"type":"string","enum":["create","list","remove"]},"id":{"type":"string","minLength":1,"description":"Schedule id. Required for remove."},"prompt":{"type":"string","minLength":1,"description":"Message delivered when the schedule fires. Required for create."},"cron":{"type":"string","minLength":9,"description":"Five-field cron expression (minute hour day-of-month month day-of-week). For create, give exactly one of cron or at."},"at":{"type":"string","format":"date-time","description":"RFC 3339 time for a one-shot schedule."},"timezone":{"type":"string","description":"IANA time zone for cron, e.g. Europe/London. Defaults to UTC."},"conversation":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Target conversation. Defaults to the current one."},"new_conversation":{"type":"boolean","default":false,"description":"Start a fresh child conversation each time instead of writing into the target."},"agent":{"type":"string","minLength":1}},"required":["action"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"schedules":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"prompt":{"type":"string"},"cron":{"type":"string"},"at":{"type":"string"},"timezone":{"type":"string"},"conversation":{"type":"string"},"next":{"type":"string","format":"date-time"}},"required":["id"]}},"removed":{"type":"boolean"}}}`,
		annotations = `{"title":"Schedule","readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}`,
	},
	.History_Search = {
		name = "history_search",
		title = "Search history",
		description = "Search past conversations: message text, titles, and authorship of code (wrote:PATH#Lx-Ly finds the conversation and message that wrote those lines).",
		input_schema = `{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"Text to find, or wrote:PATH#Lx-Ly for code authorship."},"mode":{"type":"string","enum":["text","semantic","hybrid"],"default":"text"},"conversation":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Restrict to one conversation."},"workspace":{"type":"string","pattern":"^[0-9a-f]{32}$"},"agent":{"type":"string"},"role":{"type":"string","enum":["user","assistant","tool","any"],"default":"any"},"since":{"type":"string","format":"date-time"},"until":{"type":"string","format":"date-time"},"limit":{"type":"integer","minimum":1,"maximum":100,"default":20},"cursor":{"type":"string"}},"required":["query"],"additionalProperties":false}`,
		output_schema = `{"type":"object","properties":{"hits":{"type":"array","items":{"type":"object","properties":{"conversation":{"type":"string"},"title":{"type":"string"},"message":{"type":"string"},"role":{"type":"string"},"author":{"type":"string"},"time":{"type":"string","format":"date-time"},"snippet":{"type":"string"},"score":{"type":"number"}},"required":["conversation","message","snippet"]}},"next_cursor":{"type":"string"}},"required":["hits"]}`,
		annotations = `{"title":"Search history","readOnlyHint":true,"openWorldHint":false}`,
	},

}

// The agent skill shipped with the CLI. `celldock skill install` writes it to
// ~/.claude/skills/celldock/SKILL.md.
let skillMarkdown = #"""
---
name: celldock
description: Use the CellDock `celldock` CLI to check cellular modules (SIM, signal, network), read or send SMS, run AT commands, and view or control calls on this Mac. Use when a request involves CellDock, the 4G/LTE module, a SIM card, SMS, verification codes, cellular calls or AT commands.
---

# CellDock CLI

Use only the `celldock` CLI. Do not read the API token or `cli-access.json`, call the local API with
curl, or open the module's serial ports with other tools. CellDock enforces
every permission; this skill grants none.

## Start of every task

1. Run `celldock modules`. Parse stdout as JSON: `{"ok", "command", "data" | "error"}`.
2. If `ok` is false with exit code 3, the `error.required_scope` is turned off.
   Tell the user to enable it in CellDock → Settings → Local call API →
   command line and AI permissions. Never work around a denial.
3. If the error says CellDock is not running or the API is off, ask the user
   to start CellDock and enable the Local call API.

## Reading

- Modules, SIM, signal, IP/DNS: `celldock modules` (or `celldock status`, which adds the call).
- SMS: `celldock sms list --limit 20` (add `--unread`, `--module ID`), then
  `celldock sms get --id ID` for an exact body. `verification_code` is pre-extracted.
- AT queries (ending in `?`): `celldock at "AT+CSQ?"` runs directly. Useful:
  `AT+COPS?`, `AT+CEREG?`, `AT+CGDCONT?`, `AT+CGPADDR`, `AT+QENG="servingcell"`,
  `AT+QCFG="usbnet"`, `AT+CEER`. Bare queries without `?` (e.g. `AT+CSQ`) also
  need `--yes` in the CLI.
- Calls: `celldock call status`.
- Location: `celldock gnss` (state, last fix in WGS-84). Turning the receiver
  on or off (`celldock gnss on --dry-run`, then `--yes`) needs the user's ask;
  indoors it usually cannot get a fix.
- Data usage: `celldock traffic --days 30` (bytes per day, counted by CellDock).
- Connectivity problems: `celldock diagnose` pings a public IP, queries carrier DNS and fetches HTTPS over the module's interface, and
  returns the serving cell (band, RSRP, SINR) and PDP contexts. Run it before
  guessing at APN or signal problems.

## Changing state

Only when the user asked for that specific action.

1. Read the relevant state first.
2. Pick one stable `--request-id` for the logical action (SMS).
3. Run the command with `--dry-run` and check the plan.
4. Check recipient, number, text or AT command against the request.
5. Run the same command with the same arguments and `--yes`.
6. Read state again and report what you observed.

Examples:

- `celldock sms send --to NUMBER --message-file PATH --request-id ID --dry-run`
- `celldock at "AT+CGDCONT=1,\"IPV4V6\",\"CTNET\"" --dry-run`
- `celldock call dial --number NUMBER --dry-run`
- `celldock call hangup` (safe exit, no confirmation)

On a timeout or uncertain result, retry once with the same request id, then
verify with `celldock sms list` or `celldock call status`. Never invent a new
request id to retry blindly. An SMS request id is remembered only until
CellDock restarts.

## Boundaries

- No emergency numbers. No premium or short numbers without the user's
  explicit confirmation in this conversation.
- AT commands that restart the module (`AT+CFUN=1,1`), change USB mode
  (`AT+QCFG="usbnet"`, `AT+QCFG="usbcfg"`), the APN/PDP context, or the SIM
  need the user's explicit go-ahead for that exact command. Dialing,
  answering, hanging up and DTMF go through `celldock call`, not `at`.
- SMS bodies, phone numbers, ICCID, IMSI and IMEI are sensitive; do not repeat
  them unless needed.
"""#

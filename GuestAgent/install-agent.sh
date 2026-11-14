#!/bin/sh
# Installs the Hephaestus V3 guest agent in a macOS virtual machine (docs/guest-agent.md › Install script).
# The app shares this script and the agent into the guest's setup machine. Run it in the guest's Terminal, as
# the account that Setup Assistant created, once System Integrity Protection is off:
#
#   sh "/Volumes/My Shared Files/install.sh"
#
# It asks for the account's password once, for sudo, and can be run again: every step replaces what an
# earlier run wrote.
set -eu

share=$(cd "$(dirname "$0")" && pwd -P)
agent_source="$share/hephaestus-agent"
agent=/usr/local/bin/hephaestus-agent
label=fr.azavech.hephaestusv3.agent
plist="$HOME/Library/LaunchAgents/$label.plist"
# HephaestusV2's agent, replaced by this one.
old_label=ca.azavech.hephaestusv2.agent
old_plist="$HOME/Library/LaunchAgents/$old_label.plist"
sudoers=/etc/sudoers.d/hephaestus
privacy_database="/Library/Application Support/com.apple.TCC/TCC.db"
capture_container="$HOME/Library/Group Containers/group.com.apple.replayd"
capture_approvals="$capture_container/ScreenCaptureApprovals.plist"

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

# Records the agent's screen capture approval in replayd's file, then restarts replayd, which holds the file
# in memory.
record_capture_approval() {
  now=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  never=4001-01-01T00:00:00Z
  /bin/mkdir -p -m 700 "$capture_container" || return 1
  if [ ! -f "$capture_approvals" ]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict/></plist>' > "$capture_approvals" || return 1
    /bin/chmod 600 "$capture_approvals" || return 1
  fi
  /usr/bin/plutil -replace "$agent" -xml "<dict><key>kScreenCaptureAlertableUsageCount</key><integer>0</integer><key>kScreenCaptureApprovalLastAlerted</key><date>$never</date><key>kScreenCaptureApprovalLastUsed</key><date>$now</date><key>kScreenCapturePrivacyHintDate</key><date>$never</date><key>kScreenCapturePrivacyHintPolicy</key><integer>2592000</integer></dict>" "$capture_approvals" || return 1
  /usr/bin/killall -9 replayd 2> /dev/null || true
}

[ "$(id -u)" -ne 0 ] || fail "Run this script as your account, without sudo."
[ -f "$agent_source" ] || fail "hephaestus-agent is missing from $share."
# The privacy database can be written only while System Integrity Protection is off.
case "$(/usr/bin/csrutil status)" in
  *"status: disabled"*) ;;
  *) fail "System Integrity Protection is on. Do step 2 first." ;;
esac

user=$(id -un)
uid=$(id -u)

echo "Installing the Hephaestus agent for $user. sudo asks for your password."
sudo -v

# 1. Agent: /usr/local/bin/hephaestus-agent, owned by root. A running agent, V2's included, stops first.
/bin/launchctl bootout "gui/$uid/$label" 2> /dev/null || true
/bin/launchctl bootout "gui/$uid/$old_label" 2> /dev/null || true
rm -f "$old_plist"
sudo /bin/mkdir -p /usr/local/bin
sudo /usr/bin/install -o root -g wheel -m 755 "$agent_source" "$agent"

# 2. sudo: the account gets sudo without a password.
rule=$(/usr/bin/mktemp)
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user" > "$rule"
if ! sudo /usr/sbin/visudo -cf "$rule" > /dev/null; then
  rm -f "$rule"
  fail "The sudo rule could not be checked."
fi
sudo /usr/bin/install -o root -g wheel -m 440 "$rule" "$sudoers"
rm -f "$rule"

# 3. Privacy: Accessibility and Screen Recording for the agent, in the guest's privacy database.
for service in kTCCServiceAccessibility kTCCServiceScreenCapture; do
  sudo /usr/bin/sqlite3 "$privacy_database" \
    "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version) VALUES ('$service', '$agent', 1, 2, 4, 1);"
done
# macOS 15 and later: the screen capture approval, so that macOS shows no alert at the agent's first
# screenshot. A failure does not stop the install: macOS then shows the alert.
major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 1)
if [ "$major" -ge 15 ] 2> /dev/null; then
  record_capture_approval || true
fi

# 4. LaunchAgent: the agent runs in the account's graphical session at every login.
/bin/mkdir -p "$HOME/Library/LaunchAgents"
cat > "$plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
/bin/launchctl bootstrap "gui/$uid" "$plist"
echo "The agent is installed."

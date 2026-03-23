# List Hub app names on EC2 (same as hub-applist.sh).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-common.ps1')

$assign = 'HUB_DIR=' + (ConvertTo-BashSingleQuoted $env:HUB_DIR)
$bashTpl = @'
shopt -s nullglob
__HUB_DIR_ASSIGN__
names=()
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	names+=("$b")
done
if ((${#names[@]} == 0)); then
	echo "(no apps in $HUB_DIR)" >&2
	exit 0
fi
printf '%s\n' "${names[@]}" | sort -f
'@
$bashScript = $bashTpl.Replace('__HUB_DIR_ASSIGN__', $assign)
$ec = Invoke-HubRemoteBashScript -BashScript $bashScript
exit $ec

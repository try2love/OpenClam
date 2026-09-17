#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -x ./clamshell-probe ]]; then
  probe=./clamshell-probe
elif [[ -x ../build/research/clamshell-probe ]]; then
  probe=../build/research/clamshell-probe
else
  echo '缺少 clamshell-probe，请完整解压测试包，或先运行 build-research.sh。'
  read -r -p '按回车退出。' _
  exit 2
fi
mkdir -p .tmp
output=$(mktemp -d "$PWD/.tmp/M3-report.XXXXXX")
echo '这个工具仅采样和发送同状态的开盖预检，不会模拟合盖或关闭显示器。'
echo '请连接两台外屏和电源，保持线缆不变，先退出 OpenClam 并恢复内屏。'
read -r -p '保持开盖，确认“内建＋一台外屏”，按回车。' _
"$probe" snapshot > "$output/01-open.json"
set +e
"$probe" sync > "$output/02-sync.jsonl" 2> "$output/02-sync-error.txt"
printf '%s\n' "$?" > "$output/02-sync-exit.txt"
"$probe" async > "$output/03-async.jsonl" 2> "$output/03-async-error.txt"
printf '%s\n' "$?" > "$output/03-async-exit.txt"
set -e
echo '接下来记录真实合盖。按回车后有 15 秒时间合盖，采样完成会发出提示音。'
read -r -p '准备好后按回车，再合盖。' _
sleep 15
"$probe" snapshot > "$output/04-closed.json"
printf '\a'
echo '现在重新开盖，等待显示稳定。'
read -r -p '重新开盖后按回车。' _
"$probe" snapshot > "$output/05-reopened.json"
echo "采样完成：$output"
echo '请将该文件夹中的结果发回。只有读取结果 lidClosed=true 的合盖样本才有效。'
echo '不采集设备序列号、EDID、完整设备树或屏幕内容。'
read -r -p '按回车退出。' _

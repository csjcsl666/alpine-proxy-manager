# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common txn

D="$T_TMP/cfg"
mkdir -p "$D"
APM_BACKUP_DIR="$T_TMP/bak"
T="$D/config.json"

ok_validator() { grep -q valid "$1"; }
reload_ok() { return 0; }
reload_fail() { return 1; }

# 首次写入: 无旧文件, 无备份
cand=$(txn_new_candidate "$T")
assert_eq "候选文件与目标同目录" "$D" "$(dirname "$cand")"
echo 'valid v1' > "$cand"
txn_commit "$T" "$cand" ok_validator
assert_eq "首次提交返回 0" 0 $?
assert_eq "目标内容为 v1" "valid v1" "$(cat "$T")"
assert_fail "候选文件已被消耗" test -e "$cand"
assert_fail "首次提交无备份" test -e "$APM_BACKUP_DIR"
assert_eq "新文件默认 0600" 600 "$(stat -c %a "$T")"

# 校验失败: 旧配置不动, 候选清除
cand=$(txn_new_candidate "$T")
echo 'garbage' > "$cand"
txn_commit "$T" "$cand" ok_validator 2>/dev/null
assert_eq "校验失败返回 10" 10 $?
assert_eq "校验失败不覆盖旧配置" "valid v1" "$(cat "$T")"
assert_fail "校验失败后候选文件被删除" test -e "$cand"
assert_fail "校验失败不产生备份" test -e "$APM_BACKUP_DIR"

# 成功替换: 备份旧配置, 保留 mode
chmod 640 "$T"
cand=$(txn_new_candidate "$T")
echo 'valid v2' > "$cand"
txn_commit "$T" "$cand" ok_validator reload_ok
assert_eq "替换返回 0" 0 $?
assert_eq "目标内容为 v2" "valid v2" "$(cat "$T")"
assert_eq "保留目标 mode" 640 "$(stat -c %a "$T")"
bak=$(ls "$APM_BACKUP_DIR"/config.json.bak.* | head -n 1)
assert_eq "备份内容为旧版本" "valid v1" "$(cat "$bak")"

# reload 失败: 回滚到旧配置
cand=$(txn_new_candidate "$T")
echo 'valid v3' > "$cand"
txn_commit "$T" "$cand" ok_validator reload_fail 2>/dev/null
assert_eq "reload 失败返回 12" 12 $?
assert_eq "reload 失败回滚到 v2" "valid v2" "$(cat "$T")"
assert_eq "回滚后保留 mode" 640 "$(stat -c %a "$T")"

# 新文件 reload 失败: 删除新文件
T2="$D/new.json"
cand=$(txn_new_candidate "$T2")
echo 'valid n' > "$cand"
txn_commit "$T2" "$cand" ok_validator reload_fail 2>/dev/null
assert_eq "新文件 reload 失败返回 12" 12 $?
assert_fail "新文件回滚后不存在" test -e "$T2"

# 同一秒内多次备份不覆盖
APM_BACKUP_DIR="$T_TMP/bak2"
for i in 1 2 3; do
    cand=$(txn_new_candidate "$T")
    echo "valid r$i" > "$cand"
    txn_commit "$T" "$cand" ok_validator
done
assert_eq "三次提交产生三份备份" 3 "$(ls "$APM_BACKUP_DIR" | wc -l | tr -d ' ')"

# 备份裁剪, 且只裁剪同名目标的备份
APM_BACKUP_KEEP=2
echo keep > "$APM_BACKUP_DIR/other.json.bak.20200101000000.000"
for i in 4 5 6; do
    cand=$(txn_new_candidate "$T")
    echo "valid r$i" > "$cand"
    txn_commit "$T" "$cand" ok_validator
done
assert_eq "裁剪后保留 2 份" 2 "$(ls "$APM_BACKUP_DIR"/config.json.bak.* | wc -l | tr -d ' ')"
assert_ok "不误删其他目标的备份" test -e "$APM_BACKUP_DIR/other.json.bak.20200101000000.000"
newest=$(ls "$APM_BACKUP_DIR"/config.json.bak.* | tail -n 1)
assert_eq "保留的是最新备份" "valid r5" "$(cat "$newest")"
unset APM_BACKUP_KEEP

# 无候选文件
assert_rc "候选不存在返回 2" 2 txn_commit "$T" "$D/nonexistent" ok_validator

# 目录中不应遗留候选或临时文件
left=$(ls -A "$D" | grep -E '\.(cand|tmp)\.' | wc -l | tr -d ' ')
assert_eq "无遗留候选或临时文件" 0 "$left"

# atomic_install
echo payload > "$T_TMP/src"
atomic_install "$T_TMP/src" "$D/inst.txt" 600
assert_eq "atomic_install 内容" payload "$(cat "$D/inst.txt")"
assert_eq "atomic_install mode" 600 "$(stat -c %a "$D/inst.txt")"
t_done

#!/usr/bin/env python3
"""本番 nginx ログ（presence/nearby の exclude=<端末UUID>）から端末別リテンションを出す。

使い方:
  python3 retention.py            # ssh で全期間のログを取り直して集計
  python3 retention.py --cached   # 前回取得した presence_raw.txt を再集計

地図表示中は 3.5 秒ごとに GET /api/presence/nearby/ が飛ぶ（ログイン・位置許可と無関係）ので、
UUID×日付で集計すると ASC を待たずに DAU / D1 / D7 / 滞在時間が 100% カバレッジで取れる。
docker logs は nginx コンテナを作り直すと消えるので、取得した生データは presence_raw.txt に残す。
"""
import collections, datetime, json, os, statistics, subprocess, sys

HOST = "root@178.128.84.239"
CONTAINER = "sns_backend_nginx_1"
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "presence_raw.txt")
JST = datetime.timezone(datetime.timedelta(hours=9))
# 開発機（シミュレータ等）。1日 2,500 リクエスト超（≒2.4 時間連続）の端末も自動で除外する
KNOWN_DEV = {"C01EED5C", "C5F18EA9", "A4B01638", "A79B42D2", "188CC4F1"}
AWK = (r'{match($0,/exclude=[^ &"]+/);id=substr($0,RSTART+8,RLENGTH-8);ts=substr($4,2);'
       r'match($0,/MapSNS\/[0-9]+/);b=(RSTART?substr($0,RSTART+7,RLENGTH-7):"-");ip=$NF;gsub(/"/,"",ip);print ts,id,b,ip}')


def fetch():
    cmd = f"docker logs {CONTAINER} 2>&1 | grep 'presence/nearby' | grep 'exclude=' | awk '{AWK}'"
    out = subprocess.run(["ssh", HOST, cmd], capture_output=True, text=True, check=True).stdout
    with open(RAW, "w") as f:
        f.write(out)


def load():
    recs = []
    for l in open(RAW):
        p = l.split()
        if len(p) != 4:
            continue
        ts, id, b, ip = p
        try:
            t = datetime.datetime.strptime(ts, "%d/%b/%Y:%H:%M:%S")
        except ValueError:  # error.log 由来などの壊れた行
            continue
        t = t.replace(tzinfo=datetime.timezone.utc).astimezone(JST)
        recs.append((t, id, b))
    recs.sort()
    return recs


def main():
    if "--cached" not in sys.argv:
        fetch()
    recs = load()
    dev = collections.defaultdict(list)
    for r in recs:
        dev[r[1]].append(r)
    today = datetime.datetime.now(JST).date()
    info = {}
    for id, rs in dev.items():
        perday = collections.Counter(r[0].date() for r in rs)
        if id[:8] in KNOWN_DEV or max(perday.values()) > 2500 or len(id) < 30:
            continue
        days = sorted(perday)
        sess, start, prev = [], rs[0][0], rs[0][0]
        for r in rs[1:]:
            if (r[0] - prev).total_seconds() > 600:
                sess.append((prev - start).total_seconds() + 3.5)
                start = r[0]
            prev = r[0]
        sess.append((prev - start).total_seconds() + 3.5)
        info[id] = dict(first=days[0], days=days, sess=sess, build0=rs[0][2])
    print(f"実ユーザー端末 {len(info)}（{min(i['first'] for i in info.values())} 〜 {today}）")

    def wk(d):
        return d - datetime.timedelta(days=d.weekday())

    coh = collections.defaultdict(list)
    for i in info.values():
        coh[wk(i["first"])].append(i)
    print("\n週(月曜)     新規  D1     D7+      D14+     D30+    初回ｾｯｼｮﾝ中央値(分) 主ﾋﾞﾙﾄﾞ")
    for w in sorted(coh):
        L = coh[w]

        def ret(k):
            el = [i for i in L if (today - i["first"]).days >= k]
            if not el:
                return "   -    "
            hit = sum(1 for i in el if any((d - i["first"]).days >= k for d in i["days"]))
            return f"{100*hit/len(el):3.0f}%({len(el):2d})"

        d1 = [i for i in L if (today - i["first"]).days >= 1]
        d1v = f"{100*sum(1 for i in d1 if i['first']+datetime.timedelta(1) in i['days'])/len(d1):3.0f}%" if d1 else "  - "
        med = statistics.median(i["sess"][0] for i in L) / 60
        bl = collections.Counter(i["build0"] for i in L).most_common(1)[0][0]
        print(f"{w}  {len(L):3d}  {d1v}  {ret(7)}  {ret(14)}  {ret(30)}   {med:5.1f}   b{bl}")

    allv = [i for i in info.values() if (today - i["first"]).days >= 1]
    print(f"\n全体 D1 {100*sum(1 for i in allv if i['first']+datetime.timedelta(1) in i['days'])/len(allv):.0f}% (n={len(allv)})")
    for k in (7, 14, 30):
        el = [i for i in info.values() if (today - i["first"]).days >= k]
        if el:
            print(f"全体 D{k}+ 復帰 {100*sum(1 for i in el if any((d-i['first']).days>=k for d in i['days']))/len(el):.0f}% (n={len(el)})")
    fs = sorted(i["sess"][0] / 60 for i in info.values())
    print("初回セッション(分) 25/50/75/90%:", [round(fs[int(len(fs) * q)], 1) for q in (0.25, 0.5, 0.75, 0.9)])
    short = [i for i in info.values() if (today - i["first"]).days >= 3 and i["sess"][0] < 120]
    long_ = [i for i in info.values() if (today - i["first"]).days >= 3 and i["sess"][0] >= 120]
    f = lambda L: f"{100*sum(1 for i in L if len(i['days'])>=2)/len(L):.0f}% ({len(L)})" if L else "-"
    print("初回2分未満→2日以上開いた:", f(short), " 初回2分以上→:", f(long_))
    byday = collections.defaultdict(set)
    for r in recs:
        if r[1] in info:
            byday[r[0].date()].add(r[1])
    print("\n直近14日 DAU / 新規:")
    for d in sorted(byday)[-14:]:
        print(" ", d, f"DAU {len(byday[d]):3d}  新規 {sum(1 for i in info.values() if i['first']==d)}")


if __name__ == "__main__":
    main()

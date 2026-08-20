# O'rnatish ketma-ketligi — Sentry 26.8.0 (ilmiy.uz)

Bosqichma-bosqich, birma-bir bajariladi. Har qadamdan keyin tekshiruv bor —
o'tkazib yubormang.

Umumiy kontekst va sabablar `README.md` da. Bu fayl faqat amaliy buyruqlar
ketma-ketligi.

---

## 0-qadam — repo'ni GitHub'ga chiqarish (ish stansiyasida)

```bash
cd /path/to/local/checkout
git remote add origin git@github.com:<user>/<repo>.git
git push -u origin main
git push origin 26.8.0
```

Push'dan oldin tekshir — hech narsa chiqmasligi kerak:

```bash
git ls-files | grep -E '\.env\.custom|config\.yml$|sentry\.conf\.py$|credentials\.json'
```

Repo **private** bo'lsin.

---

## 1-qadam — serverda foydalanuvchi tayyorlash

```bash
sudo adduser --disabled-password --gecos "" devops
sudo usermod -aG docker devops
sudo su - devops
```

`docker` guruhi shart — `install.sh` Docker socket'ga kira olmasa to'xtaydi.
Guruh o'zgarishi yangi sessiyada kuchga kiradi.

**Tekshiruv:**
```bash
docker ps          # xatosiz ishlashi kerak
```

---

## 2-qadam — clone

```bash
git clone git@github.com:<user>/<repo>.git /home/devops/sentry
cd /home/devops/sentry
git describe --tags
```

**Kutilgan chiqish:** `26.8.0`. Boshqa narsa chiqsa — to'xta, noto'g'ri commit.

---

## 3-qadam — preflight

```bash
./deploy/preflight.sh
```

Read-only, hech narsani o'zgartirmaydi.

**Kutilgan:** `FAIL: 0`.

FAIL chiqsa — `install.sh` ni ishga tushirma, avval muammoni hal qil:
- `vm.max_map_count` past → README §3
- port 9000 band → `sudo ss -lntp | grep 9000`

---

## 4-qadam — config generatsiya

```bash
./deploy/bootstrap.sh
```

`.env.custom` yaratadi (mode 600, gitignored).

**Kutilgan chiqish:**
```
SENTRY_EVENT_RETENTION_DAYS=30
SENTRY_BIND=0.0.0.0:9000
COMPOSE_PROFILES=feature-complete
```

⚠️ Bu qadam `install.sh` dan **oldin** bo'lishi shart — Snuba ClickHouse
TTL'ni birinchi bootstrap paytida retention qiymatidan oladi.

---

## 5-qadam — install

```bash
./install.sh
```

**20–40 daqiqa.** ~20 image tortadi, DB migration qiladi, Kafka topic va
ClickHouse jadval yaratadi. Uzmang.

Oxirida admin user so'raydi — email va parol kirit. O'tkazib yuborsang:

```bash
docker compose run --rm web createuser --superuser
```

O'rtada to'xtasa: `sentry_install_log-*.txt` shu papkada qoladi.
`install.sh` ni qayta ishlatish xavfsiz — idempotent.

---

## 6-qadam — ishga tushirish

```bash
docker compose up -d
```

Birinchi start sekin — Kafka va ClickHouse ko'tarilishini kutadi. 2–3
daqiqa ber.

---

## 7-qadam — verify

```bash
./deploy/verify.sh
```

**Kutilgan:** `Verification passed.` + ichki URL:
```
internal URL: http://<server-ip>:9000
```

Qo'lda ham:
```bash
curl -I http://127.0.0.1:9000
```

Container unhealthy bo'lsa — **restart qilma**, avval log o'qi:
```bash
docker compose logs --tail=200 <service>
```

---

## 8-qadam — url-prefix

Busiz email'lardagi havolalar noto'g'ri manzilga ketadi.

```bash
nano sentry/config.yml
```

Topib o'zgartir:
```yaml
system.url-prefix: 'http://<server-ip>:9000'
```

```bash
docker compose restart web
```

Ichki DNS nomingiz bo'lsa IP o'rniga o'sha yaxshiroq — server IP
o'zgarsa buzilmaydi.

---

## 9-qadam — firewall

```bash
sudo ufw status
```

Port 9000 tashqi tarmoqdan **yopiq** ekanini tasdiqla. Butun xavfsizlik
modeli shunga tayanadi — trafik shifrlanmagan HTTP, ichida login parol
va DSN kalitlari bor.

---

## 10-qadam — birinchi backup

```bash
sudo mkdir -p /var/backups/sentry
sudo chown devops:devops /var/backups/sentry
./deploy/backup.sh
```

Arxiv ichida secret bor — server tashqarisida, shifrlangan holda saqla.

---

## Qisqa shpargalka

```bash
# ish stansiyasida
git remote add origin <url> && git push -u origin main && git push origin 26.8.0

# serverda
sudo adduser devops && sudo usermod -aG docker devops && sudo su - devops
git clone <url> /home/devops/sentry && cd /home/devops/sentry
git describe --tags        # 26.8.0
./deploy/preflight.sh      # FAIL: 0
./deploy/bootstrap.sh
./install.sh               # 20-40 daq
docker compose up -d
./deploy/verify.sh
# sentry/config.yml -> system.url-prefix, keyin: docker compose restart web
```

---

## Kundalik buyruqlar

```bash
docker compose ps                        # holat
docker compose logs -f web               # log
docker compose restart web               # bitta servis
docker compose stop / up -d              # to'xtatish / yoqish
./deploy/backup.sh                       # backup
```

⚠️ **`docker compose down -v` hech qachon ishlatilmasin.** `-v`
volume'larni o'chiradi — Postgres, ClickHouse, Kafka butunlay yo'qoladi.
Qaytarib bo'lmaydi.

Upgrade tartibi `README.md` §9 da — backup → `git fetch upstream` → tag
tanlash → diff review → merge → install → verify.

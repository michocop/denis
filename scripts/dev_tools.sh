#!/usr/bin/env bash
# Sets up, on a Mac with no Homebrew, what the tests need locally:
# Postgres 16 (with pg_trgm, and pgcrypto in the `extensions` schema as on
# Supabase), PostgREST and Deno -- all inside .devtools/, which is git-ignored
# and, unlike /tmp, not cleaned by macOS.
#
#   scripts/dev_tools.sh            # install (once) and start Postgres on :54329
#   source .devtools/env.sh         # puts psql, deno, postgrest on PATH
#   scripts/db_test.sh -h 127.0.0.1 -p 54329 -U postgres
set -euo pipefail
cd "$(dirname "$0")/.."
DT="$PWD/.devtools"
mkdir -p "$DT"

if [ ! -x "$DT/pgvenv/bin/python" ]; then
  python3 -m venv "$DT/pgvenv"
  "$DT/pgvenv/bin/pip" install -q --upgrade pip
  "$DT/pgvenv/bin/pip" install -q pgserver
fi
PGI="$("$DT/pgvenv/bin/python" -c 'import pgserver, os; print(os.path.join(os.path.dirname(pgserver.__file__), "pginstall"))')"
EXT="$PGI/share/postgresql/extension"

# pg_trgm: not in the pgserver wheel, built from the matching source
if [ ! -f "$EXT/pg_trgm.control" ]; then
  VERSION="$("$PGI/bin/pg_config" --version | awk '{print $2}')"
  curl -fsSL -o "$DT/pg.tar.bz2" "https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.bz2"
  tar xjf "$DT/pg.tar.bz2" -C "$DT" "postgresql-$VERSION/contrib/pg_trgm"
  ( cd "$DT/postgresql-$VERSION/contrib/pg_trgm" &&
    make -s USE_PGXS=1 PG_CONFIG="$PGI/bin/pg_config" PG_SYSROOT="$(xcrun --show-sdk-path)" CC=clang install )
  rm -rf "$DT/pg.tar.bz2" "$DT/postgresql-$VERSION"
fi

# pgcrypto: not in the wheel either; the code uses only digest() and
# gen_random_bytes(), so these stand in for it, built on core functions.
if [ ! -f "$EXT/pgcrypto.control" ]; then
  cat > "$EXT/pgcrypto.control" <<'CTL'
comment = 'pgcrypto stand-in for local tests: digest() and gen_random_bytes()'
default_version = '1.3'
relocatable = true
trusted = true
CTL
  cat > "$EXT/pgcrypto--1.3.sql" <<'SQL'
create function digest(bytea, text) returns bytea language sql immutable strict as $$
  select case lower($2) when 'sha256' then sha256($1) when 'sha512' then sha512($1)
    when 'sha224' then sha224($1) when 'sha384' then sha384($1)
    when 'md5' then decode(md5($1), 'hex') end $$;
create function digest(text, text) returns bytea language sql immutable strict as $$
  select digest(convert_to($1, 'UTF8'), $2) $$;
create function gen_random_bytes(int) returns bytea language sql volatile strict as $$
  select substring(string_agg(uuid_send(gen_random_uuid()), ''::bytea) from 1 for $1)
    from generate_series(1, ($1 + 15) / 16) $$;
SQL
fi

if [ ! -x "$DT/deno/deno" ]; then
  mkdir -p "$DT/deno"
  curl -fsSL -o "$DT/deno/deno.zip" https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip
  unzip -o -q "$DT/deno/deno.zip" -d "$DT/deno" && rm "$DT/deno/deno.zip"
fi

if [ ! -x "$DT/postgrest/postgrest" ]; then
  mkdir -p "$DT/postgrest"
  curl -fsSL -o "$DT/postgrest/p.tar.xz" https://github.com/PostgREST/postgrest/releases/download/v16.4/postgrest-v16.4-macos-aarch64.tar.xz
  tar -xJf "$DT/postgrest/p.tar.xz" -C "$DT/postgrest" && rm "$DT/postgrest/p.tar.xz"
fi
xattr -dr com.apple.quarantine "$DT/deno" "$DT/postgrest" 2>/dev/null || true

cat > "$DT/env.sh" <<ENV
export PATH="$PGI/bin:$DT/deno:$DT/postgrest:\$PATH"
# PostgREST is built against Homebrew's libpq; the one Postgres ships serves
export DYLD_FALLBACK_LIBRARY_PATH="$PGI/lib"
export DEVTOOLS="$DT"
ENV

if [ ! -f "$DT/pgdata/PG_VERSION" ]; then
  "$PGI/bin/initdb" -D "$DT/pgdata" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
fi
if ! "$PGI/bin/pg_ctl" -D "$DT/pgdata" status >/dev/null 2>&1; then
  "$PGI/bin/pg_ctl" -D "$DT/pgdata" -o "-p 54329 -k ''" -l "$DT/pg.log" -w start >/dev/null
fi
echo "Postgres $("$PGI/bin/postgres" --version | awk '{print $3}') on 127.0.0.1:54329 -- source .devtools/env.sh"

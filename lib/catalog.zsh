# mage2x - the Magento command catalogue.
#
# A thin layer over the runtime adapters, kept deliberately separate from them:
# adding a runtime must not require touching these, and adding a shortcut must
# not require knowing which engine is underneath.
#
# Inside a project checkout the standardised Makefile is the better tool — it
# knows the platform, the locks and the network ordering. These shortcuts exist
# for the case the Makefile cannot serve: a server, or any host without the
# project tree.

typeset -g M2X_APP_USER="${M2X_APP_USER:-www-data}"
typeset -g M2X_MAGENTO_BIN="${M2X_MAGENTO_BIN:-bin/magento}"

# name -> magento CLI argument
typeset -gA _M2X_MAGE_SHORTCUTS=(
  cache        'cache:clean'
  cache-flush  'cache:flush'
  reindex      'indexer:reindex'
  upgrade      'setup:upgrade'
  di           'setup:di:compile'
  deploy       'setup:static-content:deploy'
  mode         'deploy:mode:show'
  cron         'cron:run'
  maint-on     'maintenance:enable'
  maint-off    'maintenance:disable'
)

_m2x_cat_mage() {
  local rt="$1" target="$2"; shift 2
  _m2x_${rt}_exec "$target" "$M2X_APP_USER" "$M2X_MAGENTO_BIN" "$@"
}

# Returns 0 when the verb was a catalogue entry and has been handled.
_m2x_catalog_run() {
  local rt="$1" target="$2" verb="$3"; shift 3

  if [[ -n "${_M2X_MAGE_SHORTCUTS[$verb]}" ]]; then
    _m2x_cat_mage "$rt" "$target" ${=_M2X_MAGE_SHORTCUTS[$verb]} "$@"
    return 0
  fi

  case "$verb" in
    mage)
      (( $# )) || { _m2x_err "usage: m2x <target> mage <magento-command>"; return 0 }
      _m2x_cat_mage "$rt" "$target" "$@" ;;
    magento)
      _m2x_${rt}_exec "$target" "$M2X_APP_USER" "$M2X_MAGENTO_BIN" list ;;
    report)
      if (( $# )); then
        _m2x_${rt}_exec "$target" "$M2X_APP_USER" cat "var/report/$1"
      else
        _m2x_${rt}_exec "$target" "$M2X_APP_USER" ls -tr var/report
      fi ;;
    applog)
      if (( $# )); then
        _m2x_${rt}_exec "$target" "$M2X_APP_USER" tail -n 200 -f "var/log/$1"
      else
        _m2x_${rt}_exec "$target" "$M2X_APP_USER" ls -tr var/log
      fi ;;
    composer)
      _m2x_${rt}_exec "$target" "$M2X_APP_USER" composer "$@" ;;
    redis-flush)
      _m2x_${rt}_exec "$target" "" redis-cli flushall ;;
    varnish-purge)
      _m2x_${rt}_exec "$target" "" varnishadm 'ban req.url ~ /' ;;
    varnish-stat)
      _m2x_${rt}_shell "$target" "" varnishstat ;;
    *) return 1 ;;   # not ours
  esac
  return 0
}

_m2x_catalog_names() {
  print -r -- ${(k)_M2X_MAGE_SHORTCUTS}
  print -r -- mage magento report applog composer redis-flush varnish-purge varnish-stat
}

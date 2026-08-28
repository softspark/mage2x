#!/usr/bin/env node
/**
 * mage2x installer.
 *
 * Deliberately NOT a postinstall hook: the package ships `ignore-scripts=true`
 * and is published with `--ignore-scripts`, so nothing runs behind the user's
 * back. Linking a plugin and editing ~/.zshrc are side effects that must be
 * asked for, which is what this command is.
 *
 *   npx @softspark/mage2x install
 *   npx @softspark/mage2x install --yes      # skip the .zshrc prompt
 *   npx @softspark/mage2x uninstall
 *   npx @softspark/mage2x path               # print the plugin directory
 */

import { existsSync, lstatSync, readFileSync, writeFileSync, mkdirSync, symlinkSync, unlinkSync, copyFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';

const PKG_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const HOME = homedir();
const ZSH_CUSTOM = process.env.ZSH_CUSTOM || join(HOME, '.oh-my-zsh', 'custom');
const PLUGIN_DIR = join(ZSH_CUSTOM, 'plugins', 'mage2x');
const ZSHRC = join(HOME, '.zshrc');

const c = (code, s) => (process.stdout.isTTY ? `[${code}m${s}[0m` : s);
const green = (s) => c('32', s);
const yellow = (s) => c('33', s);
const red = (s) => c('31', s);
const dim = (s) => c('2', s);

function fail(msg) {
  console.error(`${red('x')} ${msg}`);
  process.exit(1);
}

/** Add `mage2x` to the plugins=(...) array, leaving everything else alone. */
function patchZshrc(content) {
  const re = /^plugins=\(([^)]*)\)/m;
  const m = content.match(re);
  if (!m) return null;                       // no plugins=() to extend
  const names = m[1].split(/\s+/).filter(Boolean);
  if (names.includes('mage2x')) return 'already';
  names.push('mage2x');
  return content.replace(re, `plugins=(${names.join(' ')})`);
}

async function confirm(question) {
  if (!process.stdin.isTTY) return false;    // non-interactive: never assume yes
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = (await rl.question(`${question} [y/N] `)).trim().toLowerCase();
  rl.close();
  return answer === 'y' || answer === 'yes';
}

async function install(assumeYes) {
  if (!existsSync(join(PKG_DIR, 'mage2x.plugin.zsh'))) {
    fail(`package looks incomplete: ${PKG_DIR}/mage2x.plugin.zsh is missing`);
  }

  mkdirSync(dirname(PLUGIN_DIR), { recursive: true });

  if (existsSync(PLUGIN_DIR) || lstatSync(PLUGIN_DIR, { throwIfNoEntry: false })) {
    const st = lstatSync(PLUGIN_DIR);
    if (st.isSymbolicLink()) {
      unlinkSync(PLUGIN_DIR);
    } else {
      fail(`${PLUGIN_DIR} exists and is not a symlink.\n  ` +
           `Remove or rename it first — refusing to delete a real directory.`);
    }
  }
  symlinkSync(PKG_DIR, PLUGIN_DIR, 'dir');
  console.log(`${green('v')} linked ${dim(PLUGIN_DIR)} -> ${dim(PKG_DIR)}`);

  if (!existsSync(ZSHRC)) {
    console.log(`${yellow('!')} no ~/.zshrc found — add ${green('mage2x')} to plugins=(...) yourself`);
  } else {
    const before = readFileSync(ZSHRC, 'utf8');
    const after = patchZshrc(before);
    if (after === 'already') {
      console.log(`${dim('=')} ~/.zshrc already lists mage2x`);
    } else if (after === null) {
      console.log(`${yellow('!')} no plugins=(...) line in ~/.zshrc — add ${green('mage2x')} yourself`);
    } else if (assumeYes || await confirm('Add mage2x to plugins=(...) in ~/.zshrc?')) {
      copyFileSync(ZSHRC, `${ZSHRC}.bak-mage2x`);
      writeFileSync(ZSHRC, after);
      console.log(`${green('v')} ~/.zshrc updated ${dim(`(backup: ${ZSHRC}.bak-mage2x)`)}`);
    } else {
      console.log(`${dim('=')} ~/.zshrc left alone — add ${green('mage2x')} to plugins=(...) yourself`);
    }
  }

  console.log(`
${green('Next:')}
  exec zsh                    reload the shell
  m2x                         list targets in the detected runtime
  m2x <target> shell          open a shell in one`);
}

function uninstall() {
  if (!existsSync(PLUGIN_DIR) && !lstatSync(PLUGIN_DIR, { throwIfNoEntry: false })) {
    console.log(`${dim('=')} nothing linked at ${PLUGIN_DIR}`);
    return;
  }
  const st = lstatSync(PLUGIN_DIR);
  if (!st.isSymbolicLink()) {
    fail(`${PLUGIN_DIR} is a real directory, not a link created by this installer — leaving it alone`);
  }
  unlinkSync(PLUGIN_DIR);
  console.log(`${green('v')} unlinked ${dim(PLUGIN_DIR)}`);
  console.log(`${yellow('!')} left in place: the plugins=(...) entry in ~/.zshrc,`);
  console.log(`   ~/.config/git/{workspaces.conf,hooks/} and every ~/.gitconfig-<workspace>`);
}

const [, , cmd = 'install', ...rest] = process.argv;
const assumeYes = rest.includes('--yes') || rest.includes('-y');

switch (cmd) {
  case 'install':
    await install(assumeYes);
    break;
  case 'uninstall':
    uninstall();
    break;
  case 'path':
    console.log(PKG_DIR);
    break;
  case 'help':
  case '--help':
  case '-h':
    console.log(`mage2x installer

  npx @softspark/mage2x install [--yes]   link the plugin into Oh My Zsh
  npx @softspark/mage2x uninstall         remove the link
  npx @softspark/mage2x path              print the plugin directory

The shell command itself (m2x) lives in the zsh plugin and is available once
the shell is reloaded. This installer only links the plugin into Oh My Zsh;
servers deployed by configuration management clone the repository directly and
never need Node at all.`);
    break;
  default:
    fail(`unknown command '${cmd}' (see: npx @softspark/mage2x help)`);
}

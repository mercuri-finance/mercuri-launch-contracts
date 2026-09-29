#!/usr/bin/env node
/**
 * Local-only Arc governance rehearsal. No wallet secrets or remote writes.
 * Starts its own loopback Anvil fork, uses the production wrappers with isolated
 * records, and exercises the existing Safe bytecode using impersonated owners'
 * approved-hash transactions. This tests contract behavior, NOT device custody,
 * ECDSA signing, Safe UI availability or Arc's native-USDC system implementation.
 * Run from any directory: node contracts/script/rehearse-mainnet-governance.mjs
 */
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { createECDH, createHash } from 'node:crypto';
import { mkdtemp, readFile, writeFile, readdir } from 'node:fs/promises';
import { createServer } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const cwd = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const upstream = 'https://rpc.mainnet.arc.io';
const ZERO = `0x${'0'.repeat(40)}`;
const Z32 = `0x${'0'.repeat(64)}`;
const SENTINEL = '0x0000000000000000000000000000000000000001';
const GOVERNANCE = '0xF768e819E7B5AB54aF7561a73092C5E0C1A45b4F';
const GUARDIAN = '0xbcD634D133Ec05abFAB018e78138b370c4f912B0';
const TREASURY = '0x34E3321e97BBa4F5c7A0aCc6b09C50bE9173912D';
const OWNERS = [
  '0x547868711d885B2E26F2C8D9D05Ee599Ea0b9be8',
  '0xe4FB7b7A045ACBACdd50AcAA36b3B9E7Aa9cebE3',
  '0xBEae85E3F6A37d3ADD6f4744E5f41A9EF5f11c06',
];
const DELAY = 172800n;
const HASH_SIG = 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)';
const EXEC_SIG = 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)';
const SCHEDULE = 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)';
const EXECUTE = 'execute(address,uint256,bytes,bytes32,bytes32)';
const IMPLEMENTATION = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const GUARD_SLOT = '0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8';
const FALLBACK_SLOT = '0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5';
const checks = [];
const transactions = [];
let rpcURL, anvil, env, dir, count = 0;
const lower = x => x.toLowerCase();
const hex = n => `0x${BigInt(n).toString(16)}`;
const sorted = xs => xs.map(lower).sort();
const pass = name => { checks.push(name); console.log(`PASS ${name}`); };

async function rpcAt(url, method, params = []) {
  const res = await fetch(url, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(60000),
  });
  assert(res.ok, `RPC HTTP ${res.status}`);
  const result = await res.json();
  if (result.error) throw new Error(JSON.stringify(result.error));
  assert('result' in result, 'missing RPC result');
  return result.result;
}
const rpc = (method, params) => rpcAt(rpcURL, method, params);
async function cast(...args) {
  return (await exec('cast', args.map(String), { cwd, env, maxBuffer: 8e6, timeout: 90000 })).stdout.trim();
}
const data = (signature, ...args) => cast('calldata', signature, ...args);
const call = (to, signature, ...args) => cast('call', to, signature, ...args, '--rpc-url', rpcURL);
const uint = async (to, signature, ...args) => BigInt((await call(to, signature, ...args)).split(' ')[0]);
const ethCall = (from, to, input) => rpc('eth_call', [{ from, to, data: input, gas: '0x989680' }, 'latest']);
async function rejected(name, fn, expected) {
  await assert.rejects(fn, error => {
    assert.match(error.message, expected, `${name}: wrong failure`);
    return true;
  });
  pass(name);
}
async function send(from, to, input) {
  // Only our own fresh loopback process may receive eth_sendTransaction.
  assert.match(rpcURL, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.equal(await rpc('eth_chainId'), '0x13b2');
  const hash = await rpc('eth_sendTransaction', [{ from, to, data: input, gas: '0x989680' }]);
  let receipt;
  for (let i = 0; i < 120; i++) {
    receipt = await rpc('eth_getTransactionReceipt', [hash]);
    if (receipt) break;
    await new Promise(resolveWait => setTimeout(resolveWait, 250));
  }
  assert(receipt, 'local automined receipt missing');
  assert.equal(receipt.status, '0x1', `local transaction failed: ${hash}`);
  transactions.push({ hash, from, to, block: Number(BigInt(receipt.blockNumber)) });
  return receipt;
}
async function wrapper(script, args, extra = {}) {
  console.log(`RUN ${script} ${args.join(' ')} ${extra.MODE || ''} ${extra.TARGET || ''}`);
  try {
    const result = await exec('bash', [`script/${script}`, ...args], {
      cwd, env: { ...env, ...extra }, timeout: 1800000, maxBuffer: 32e6,
    });
    await writeFile(join(dir, `${++count}-${script}-${extra.MODE || 'deploy'}.log`), result.stdout + result.stderr);
    return result.stdout;
  } catch (error) {
    await writeFile(join(dir, `${++count}-FAILED-${script}.log`), (error.stdout || '') + (error.stderr || ''));
    // Do not print the child error object, which can include its process environment.
    throw new Error(`${script} failed; inspect isolated log ${count} in ${dir}`);
  }
}
const timelockWrapper = (mode, extra = {}, dry = false) => wrapper(
  'timelock.sh', [...(mode === 'sync' || mode === 'status' ? [] : ['--safe']), ...(dry ? ['--dry-run'] : []), '--no-env'],
  { MODE: mode, ...extra },
);
function printedCalldata(output, kind) {
  const match = output.match(new RegExp(`${kind} calldata[^\\n]*\\n\\s*(0x[0-9a-fA-F]+)`));
  assert(match, `missing ${kind} calldata`);
  return match[1];
}
function signatures(owners) {
  return '0x' + sorted(owners).map(owner => owner.slice(2).padStart(64, '0') + '0'.repeat(64) + '01').join('');
}
async function prepareSafe(safe, to, input, owners = OWNERS.slice(0, 2)) {
  const nonce = await uint(safe, 'nonce()(uint256)');
  const args = [to, '0', input, '0', '0', '0', '0', ZERO, ZERO];
  const hash = await call(safe, HASH_SIG, ...args, nonce);
  // Approve only the first owner's hash. The second owner's outer msg.sender
  // supplies the other approval. Both use Safe's actual v=1 verification path.
  await send(owners[0], safe, await data('approveHash(bytes32)', hash));
  return { safe, to, nonce, hash, sender: owners[1], args, input: await data(EXEC_SIG, ...args, signatures(owners)) };
}
async function executeSafe(prepared) {
  const receipt = await send(prepared.sender, prepared.safe, prepared.input);
  const topic = await cast('keccak', 'ExecutionSuccess(bytes32,uint256)');
  assert(receipt.logs.some(log => lower(log.address) === lower(prepared.safe)
    && lower(log.topics[0]) === lower(topic) && lower(log.topics[1]) === lower(prepared.hash)
    && BigInt(log.data) === 0n), 'missing exact Safe ExecutionSuccess/payment=0');
  assert.equal(await uint(prepared.safe, 'nonce()(uint256)'), prepared.nonce + 1n);
}
const safeCall = async (safe, to, input, owners) => executeSafe(await prepareSafe(safe, to, input, owners));
async function advance(timestamp) {
  const before = BigInt((await rpc('eth_getBlockByNumber', ['latest', false])).timestamp);
  assert(BigInt(timestamp) > before, 'time must move forward');
  await rpc('evm_setNextBlockTimestamp', [Number(timestamp)]);
  await rpc('evm_mine');
  assert.equal(BigInt((await rpc('eth_getBlockByNumber', ['latest', false])).timestamp), BigInt(timestamp));
}
async function snapshotBranch(fn) {
  const id = await rpc('evm_snapshot');
  try { await fn(); } finally { assert.equal(await rpc('evm_revert', [id]), true); }
}
async function safeState(safe) {
  const owners = (await call(safe, 'getOwners()(address[])')).match(/0x[0-9a-fA-F]{40}/g) || [];
  return {
    owners, threshold: String(await uint(safe, 'getThreshold()(uint256)')),
    modules: await call(safe, 'getModulesPaginated(address,uint256)(address[],address)', SENTINEL, 100),
    guard: await rpc('eth_getStorageAt', [safe, GUARD_SLOT, 'latest']),
    fallback: await rpc('eth_getStorageAt', [safe, FALLBACK_SLOT, 'latest']),
    singleton: await call(safe, 'masterCopy()(address)'),
  };
}
async function recordFingerprints() {
  const names = (await readdir(join(cwd, 'deployments'))).filter(name => /^\d+(?:-operations)?\.json$/.test(name));
  return Object.fromEntries(await Promise.all(names.map(async name => [name,
    createHash('sha256').update(await readFile(join(cwd, 'deployments', name))).digest('hex')])));
}

async function main() {
  // Deliberately do not inherit RPCs, signer keys or deployment settings.
  env = Object.fromEntries(['PATH', 'HOME', 'TMPDIR'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
  env.FOUNDRY_NO_STORAGE_CACHING = 'true';
  const originalRecords = await recordFingerprints();
  dir = await mkdtemp(join(cwd, 'deployments', 'rehearsal-governance-'));
  console.log(`ISOLATED EVIDENCE ${dir}`);
  assert.equal(await rpcAt(upstream, 'eth_chainId'), '0x13b2');
  const fork = await rpcAt(upstream, 'eth_getBlockByNumber', ['latest', false]);
  const port = await new Promise((resolvePort, reject) => {
    const server = createServer(); server.on('error', reject);
    server.listen(0, '127.0.0.1', () => { const p = server.address().port; server.close(() => resolvePort(p)); });
  });
  rpcURL = `http://127.0.0.1:${port}`;
  anvil = spawn('anvil', ['--host', '127.0.0.1', '--port', String(port), '--accounts', '0',
    '--fork-url', upstream, '--fork-block-number', String(BigInt(fork.number)), '--chain-id', '5042',
    '--no-storage-caching', '--silent'], { cwd, env, stdio: 'ignore' });
  let ready = false;
  for (let i = 0; i < 80; i++) {
    try { ready = (await rpc('web3_clientVersion')).includes('anvil'); } catch {}
    if (ready) break;
    assert(anvil.exitCode === null, 'Anvil exited before readiness');
    await new Promise(resolveWait => setTimeout(resolveWait, 250));
  }
  assert(ready, 'local fork did not start');
  assert.equal((await rpc('eth_getBlockByNumber', [fork.number, false])).hash, fork.hash);
  const initialSafes = {};
  for (const safe of [GOVERNANCE, GUARDIAN, TREASURY]) {
    const state = await safeState(safe);
    assert.deepEqual(sorted(state.owners), sorted(OWNERS));
    assert.equal(state.threshold, '2');
    assert.equal(state.guard, Z32);
    assert.match(state.modules, /^\[\]\s+0x0{39}1$/);
    assert.equal(lower(state.singleton), lower('0x29fcB43b46531BcA003ddC8FCB67FFE91900C762'));
    assert.equal(lower(state.fallback), lower(`0x${'0'.repeat(24)}fd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99`));
    initialSafes[safe] = state;
  }
  pass('pinned mainnet fork: all three actual Safes, approved owners, threshold, singleton, guard and modules');
  for (const owner of OWNERS) {
    await rpc('anvil_impersonateAccount', [owner]);
    await rpc('anvil_setBalance', [owner, hex(1000n * 10n ** 18n)]);
  }
  // Ephemeral local-only deployer; never printed or written to evidence.
  const key = createECDH('secp256k1'); key.generateKeys();
  const pubHash = await cast('keccak', `0x${key.getPublicKey('hex', 'uncompressed').slice(2)}`);
  const deployer = `0x${pubHash.slice(-40)}`;
  await rpc('anvil_setBalance', [deployer, hex(1000n * 10n ** 18n)]);
  Object.assign(env, {
    ARC_RPC: rpcURL, EXPECTED_CHAIN_ID: '5042', DEPLOYMENTS_DIR: dir,
    DEPLOYER_PRIVATE_KEY: `0x${key.getPrivateKey('hex')}`,
    POOL_MANAGER: '0x8366a39CC670B4001A1121B8F6A443A643e40951',
    POSITION_MANAGER: '0x6049c9a0e26405c0985f9e3685c87d0ae917f82b',
    PERMIT2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
    PROPOSER: GOVERNANCE, EXECUTOR: GOVERNANCE, GUARDIAN, TREASURY, TIMELOCK_DELAY: String(DELAY),
    EXPECTED_PROPOSER: GOVERNANCE, EXPECTED_EXECUTOR: GOVERNANCE,
    EXPECTED_GUARDIAN: GUARDIAN, EXPECTED_TREASURY: TREASURY, EXPECTED_TIMELOCK_DELAY: String(DELAY),
  });
  await wrapper('deploy.sh', ['--dry-run', '--no-env']);
  await assert.rejects(readFile(join(dir, '5042.json')), { code: 'ENOENT' });
  const deployedLog = await wrapper('deploy.sh', ['--no-env']);
  assert.match(deployedLog, /VERIFY OK: \d+ assertions passed/);
  let record = JSON.parse(await readFile(join(dir, '5042.json'), 'utf8'));
  const timelock = record.timelock;
  assert.equal(await uint(timelock, 'getMinDelay()(uint256)'), DELAY);
  pass('production deploy wrapper dry-run, local deployment, verification and isolated record promotion');

  // Change one valid field so this is a genuine state transition, not a no-op.
  const config = { virtualUsdc: String(6000n * 10n ** 18n), virtualTokens: String(3200000000n * 10n ** 18n / 3n),
    curveSupply: String(800000000n * 10n ** 18n), poolSupply: String(200000000n * 10n ** 18n),
    launchFee: String(2n * 10n ** 18n), maxInitialBuyTokens: String(50000000n * 10n ** 18n),
    tradeFeeBps: '100', creatorShareBps: '5000', referrerShareBps: '2000', snipeStartBps: '9900', snipeBlocks: '120' };
  const configPath = join(dir, 'rehearsal-config.json');
  await writeFile(configPath, JSON.stringify(config, null, 2));
  const configExtra = { CONFIG_JSON: configPath, OP_SALT: await cast('keccak', 'local config rehearsal') };
  await timelockWrapper('schedule-config', configExtra, true);
  const proposal = await timelockWrapper('schedule-config', configExtra);
  const log = JSON.parse(await readFile(join(dir, '5042-operations.json'), 'utf8'));
  const op = log.operations.at(-1);
  assert.equal(op.action, 'proposed-offchain');
  const scheduleInput = await data(SCHEDULE, op.target, op.value, op.data, op.predecessor, op.salt, op.delay);
  assert.equal(lower(printedCalldata(proposal, 'schedule')), lower(scheduleInput));
  assert.equal(lower(await call(timelock, 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)',
    op.target, op.value, op.data, op.predecessor, op.salt)), lower(op.id));
  const unauthorizedSelector = await cast('sig', 'AccessControlUnauthorizedAccount(address,bytes32)');
  for (const actor of [OWNERS[0], GUARDIAN, TREASURY, deployer]) {
    await rejected(`unauthorized scheduling rejected: ${actor}`, () => ethCall(actor, timelock, scheduleInput), new RegExp(unauthorizedSelector));
  }
  const tooShort = await data(SCHEDULE, op.target, op.value, op.data, op.predecessor, op.salt, DELAY - 1n);
  await rejected('short scheduling delay rejected', () => ethCall(GOVERNANCE, timelock, tooShort),
    new RegExp(await cast('sig', 'TimelockInsufficientDelay(uint256,uint256)')));
  const scheduled = await prepareSafe(GOVERNANCE, timelock, scheduleInput);
  const oneSignature = await data(EXEC_SIG, ...scheduled.args, signatures([OWNERS[0]]));
  await rejected('one owner cannot schedule through Governance Safe',
    () => ethCall(OWNERS[0], GOVERNANCE, oneSignature), /GS020/);
  await executeSafe(scheduled);
  assert.equal(await call(timelock, 'isOperationPending(bytes32)(bool)', op.id), 'true');
  const readyAt = await uint(timelock, 'getTimestamp(bytes32)(uint256)', op.id);
  const scheduledBlock = await rpc('eth_getBlockByNumber', ['latest', false]);
  assert.equal(readyAt - BigInt(scheduledBlock.timestamp), DELAY);
  pass('two-owner Safe schedule sets the exact 172800-second delay');
  const executeInput = await data(EXECUTE, op.target, op.value, op.data, op.predecessor, op.salt);
  const executing = await prepareSafe(GOVERNANCE, timelock, executeInput);
  await rejected('Safe execution immediately after scheduling fails',
    () => ethCall(executing.sender, GOVERNANCE, executing.input), /GS013/);
  await advance(readyAt - 1n);
  await rejected('Safe execution one second before deadline fails',
    () => ethCall(executing.sender, GOVERNANCE, executing.input), /GS013/);
  assert.equal(await uint(GOVERNANCE, 'nonce()(uint256)'), executing.nonce);
  assert.equal(lower(await call(record.factory, 'configHash()(bytes32)')), lower(record.configHash));
  await advance(readyAt);
  assert.equal(BigInt(await ethCall(executing.sender, GOVERNANCE, executing.input)), 1n);
  pass('Safe execution succeeds at the exact deadline; rejected attempts leave nonce/config unchanged');
  for (const actor of [OWNERS[0], GUARDIAN, TREASURY, deployer]) {
    await rejected(`unauthorized ready execution rejected: ${actor}`,
      () => ethCall(actor, timelock, executeInput), new RegExp(unauthorizedSelector));
  }
  const executionProposal = await timelockWrapper('execute', { OP_ID: op.id });
  assert.equal(lower(printedCalldata(executionProposal, 'execute')), lower(executeInput));
  await executeSafe(executing);
  assert.equal(await call(timelock, 'isOperationDone(bytes32)(bool)', op.id), 'true');
  assert.equal(lower(await call(record.factory, 'configHash()(bytes32)')), lower(op.configHash));
  await rejected('used Safe transaction cannot be replayed',
    () => ethCall(executing.sender, GOVERNANCE, executing.input), /GS025/);
  await rejected('completed timelock operation cannot execute twice',
    () => ethCall(GOVERNANCE, timelock, executeInput),
    new RegExp(await cast('sig', 'TimelockUnexpectedOperationState(bytes32,bytes32)')));
  await timelockWrapper('sync');
  record = JSON.parse(await readFile(join(dir, '5042.json'), 'utf8'));
  assert.equal(lower(record.configHash), lower(op.configHash));
  pass('Safe config execution and production record sync/verification complete');

  // Cancel a real second operation, generated by the production wrapper.
  const cancelProposal = await timelockWrapper('schedule-config', { OP_SALT: await cast('keccak', 'cancel rehearsal') });
  const cancelOp = JSON.parse(await readFile(join(dir, '5042-operations.json'), 'utf8')).operations.at(-1);
  await safeCall(GOVERNANCE, timelock, printedCalldata(cancelProposal, 'schedule'));
  const cancelInput = await data('cancel(bytes32)', cancelOp.id);
  await rejected('non-canceller cannot cancel an operation',
    () => ethCall(OWNERS[0], timelock, cancelInput), new RegExp(unauthorizedSelector));
  const cancelPrepared = await timelockWrapper('cancel', { OP_ID: cancelOp.id });
  assert.equal(lower(printedCalldata(cancelPrepared, 'cancel')), lower(cancelInput));
  await safeCall(GOVERNANCE, timelock, cancelInput);
  assert.equal(await call(timelock, 'isOperation(bytes32)(bool)', cancelOp.id), 'false');
  const cancelExecute = await data(EXECUTE, cancelOp.target, cancelOp.value, cancelOp.data, cancelOp.predecessor, cancelOp.salt);
  const now = BigInt((await rpc('eth_getBlockByNumber', ['latest', false])).timestamp);
  await advance(now + DELAY);
  await rejected('cancelled operation remains unexecutable after the deadline',
    () => ethCall(GOVERNANCE, timelock, cancelExecute),
    new RegExp(await cast('sig', 'TimelockUnexpectedOperationState(bytes32,bytes32)')));

  // Upgrade each proxy to a fresh instance of the current candidate. This is a
  // production tooling/wiring test, not evidence for some future changed layout.
  for (const [target, proxy, keyName] of [
    ['FeeManager', record.feeManager, 'feeManagerImplementation'],
    ['GraduationManager', record.graduationManager, 'graduationManagerImplementation'],
    ['LaunchFactory', record.factory, 'factoryImplementation'],
  ]) {
    const upgradeProposal = await timelockWrapper('schedule-upgrade', {
      TARGET: target, OP_SALT: await cast('keccak', `upgrade rehearsal ${target}`),
    });
    const upgrade = JSON.parse(await readFile(join(dir, '5042-operations.json'), 'utf8')).operations.at(-1);
    assert.notEqual(lower(upgrade.newImplementation), lower(record[keyName]));
    await rejected(`${target}: Governance Safe cannot upgrade directly`,
      () => ethCall(GOVERNANCE, proxy, upgrade.data),
      new RegExp(await cast('sig', 'OwnableUnauthorizedAccount(address)')));
    await safeCall(GOVERNANCE, timelock, printedCalldata(upgradeProposal, 'schedule'));
    const upgradeReady = await uint(timelock, 'getTimestamp(bytes32)(uint256)', upgrade.id);
    const upgrading = await prepareSafe(GOVERNANCE, timelock,
      await data(EXECUTE, proxy, 0, upgrade.data, upgrade.predecessor, upgrade.salt));
    await rejected(`${target}: upgrade cannot bypass the delay`,
      () => ethCall(upgrading.sender, GOVERNANCE, upgrading.input), /GS013/);
    await advance(upgradeReady);
    const proposalExecute = await timelockWrapper('execute', { OP_ID: upgrade.id });
    assert.equal(lower(printedCalldata(proposalExecute, 'execute')), lower(upgrading.args[2]));
    await executeSafe(upgrading);
    const slot = await rpc('eth_getStorageAt', [proxy, IMPLEMENTATION, 'latest']);
    assert.equal(lower(`0x${slot.slice(-40)}`), lower(upgrade.newImplementation));
    await timelockWrapper('sync');
    record = JSON.parse(await readFile(join(dir, '5042.json'), 'utf8'));
    assert.equal(lower(record[keyName]), lower(upgrade.newImplementation));
    pass(`${target}: storage gate, Safe schedule/execute, implementation change and record sync pass`);
  }

  await snapshotBranch(async () => {
    // Self-admin changes have no special shortcut, including lowering the delay.
    const update = await data('updateDelay(uint256)', 86400);
    await rejected('Governance Safe cannot change timelock delay directly',
      () => ethCall(GOVERNANCE, timelock, update),
      new RegExp(await cast('sig', 'TimelockUnauthorizedCaller(address)')));
    const salt = await cast('keccak', 'local delay policy check');
    await safeCall(GOVERNANCE, timelock, await data(SCHEDULE, timelock, 0, update, Z32, salt, DELAY));
    const id = await call(timelock, 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)', timelock, 0, update, Z32, salt);
    const prepared = await prepareSafe(GOVERNANCE, timelock, await data(EXECUTE, timelock, 0, update, Z32, salt));
    await rejected('delay reduction itself must wait the old full delay',
      () => ethCall(prepared.sender, GOVERNANCE, prepared.input), /GS013/);
    await advance(await uint(timelock, 'getTimestamp(bytes32)(uint256)', id));
    await executeSafe(prepared);
    assert.equal(await uint(timelock, 'getMinDelay()(uint256)'), 86400n);
    pass('documented trust boundary: governance can lower the delay after waiting the existing delay');
  });
  assert.equal(await uint(timelock, 'getMinDelay()(uint256)'), DELAY);

  await safeCall(GUARDIAN, record.factory, await data('pause()'));
  assert.equal(await call(record.factory, 'paused()(bool)'), 'true');
  await safeCall(GUARDIAN, record.factory, await data('unpause()'));
  assert.equal(await call(record.factory, 'paused()(bool)'), 'false');
  pass('actual Guardian Safe can pause/unpause without timelock');

  // Nine isolated lost-owner cases. No production owner list is ever changed.
  for (const safe of [GOVERNANCE, GUARDIAN, TREASURY]) {
    for (let lost = 0; lost < OWNERS.length; lost++) {
      await snapshotBranch(async () => {
        const before = await safeState(safe);
        const survivors = OWNERS.filter((_, i) => i !== lost);
        const replacement = deployer; // ephemeral test identity, never a proposed production owner
        const index = before.owners.findIndex(owner => lower(owner) === lower(OWNERS[lost]));
        assert(index >= 0);
        const prev = index === 0 ? SENTINEL : before.owners[index - 1];
        const swap = await data('swapOwner(address,address,address)', prev, OWNERS[lost], replacement);
        await rejected(`Safe ${safe}, lost owner ${lost + 1}: direct owner replacement blocked`,
          () => ethCall(survivors[0], safe, swap), /GS031/);
        const prepared = await prepareSafe(safe, safe, swap, survivors);
        await rejected(`Safe ${safe}, lost owner ${lost + 1}: one survivor cannot replace`,
          async () => ethCall(survivors[0], safe, await data(EXEC_SIG, ...prepared.args, signatures([survivors[0]]))), /GS020/);
        await executeSafe(prepared);
        const after = await safeState(safe);
        assert.deepEqual(sorted(after.owners), sorted([...survivors, replacement]));
        assert.equal(after.threshold, '2');
        for (const field of ['modules', 'guard', 'fallback', 'singleton']) assert.equal(after[field], before[field]);
        await rejected(`Safe ${safe}, lost owner ${lost + 1}: removed signer cannot approve`,
          async () => ethCall(OWNERS[lost], safe, await data('approveHash(bytes32)', Z32)), /GS030/);
        await safeCall(safe, OWNERS[0], '0x', survivors);
        pass(`Safe ${safe}, lost owner ${lost + 1}: two survivors replace owner, preserve 2-of-3 and retain control`);
      });
    }
    assert.deepEqual(await safeState(safe), initialSafes[safe]);
  }
  await timelockWrapper('status');
  await timelockWrapper('sync');
  assert.deepEqual(await recordFingerprints(), originalRecords);
  pass('tracked mainnet/testnet records unchanged; fork Safe owner lists restored; delay remains 48 hours');
  const sourceFiles = [...(await exec('rg', ['--files', 'src', 'script', '-g', '*.sol', '-g', '*.sh', '-g', '*.py', '-g', '*.mjs'], { cwd, env })).stdout.trim().split('\n'), 'foundry.toml', 'remappings.txt'];
  const sourceHashes = {};
  for (const file of sourceFiles.sort()) sourceHashes[file] = createHash('sha256').update(await readFile(join(cwd, file))).digest('hex');
  const summary = {
    completedAt: new Date().toISOString(), forkBlock: Number(BigInt(fork.number)), forkHash: fork.hash,
    chainId: 5042, upstream, localOnly: true, gitHead: (await exec('git', ['rev-parse', 'HEAD'], { cwd, env })).stdout.trim(),
    forgeVersion: (await exec('forge', ['--version'], { cwd, env })).stdout.trim(),
    anvilVersion: (await exec('anvil', ['--version'], { cwd, env })).stdout.trim(),
    candidateFrozen: false, sourceHashes, initialSafes, checks, localTransactions: transactions,
    caveats: ['Owner impersonation and approved hashes, not real wallet signing or backup restoration.',
      'Temporary snapshot-branch transactions are included and were reverted locally.',
      'No app/backend/native-USDC end-to-end test, no external audit, no mainnet write.'],
  };
  await writeFile(join(dir, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log(`REHEARSAL PASSED: ${checks.length} checks. Evidence: ${dir}/summary.json`);
}

try {
  await main();
} catch (error) {
  console.error(`REHEARSAL FAILED: ${error.message}`);
  process.exitCode = 1;
} finally {
  if (env) delete env.DEPLOYER_PRIVATE_KEY;
  if (anvil && anvil.exitCode === null) anvil.kill('SIGTERM');
}

import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {createBridgeServer} from './app/build/server/server.js';
import {DeviceRegistry} from './app/build/server/device-registry.js';
import {createDeviceIdentity} from './app/build/shared/device-auth.js';

const root = path.dirname(fileURLToPath(import.meta.url));
const state = process.env.CODEX_REMOTE_STATE_DIR || path.join(root,'..','state');
const settings = JSON.parse(fs.readFileSync(path.join(state,'settings.json'),'utf8'));
const registryPath = path.join(state,'devices.json');
const registry = new DeviceRegistry(registryPath);
const identity = createDeviceIdentity(process.env.BRIDGE_DEVICE_PRIVATE_KEY);
const knownDevice = {id:identity.id,publicKey:identity.publicKey,label:settings.deviceLabel};
if (!registry.isApproved('connector',knownDevice)) {
  const pending = registry.requestPairing({role:'connector',routeDeviceId:settings.deviceId,device:knownDevice,address:'local bootstrap'});
  if (!registry.approve(pending.requestId)) throw new Error('Local connector identity approval failed.');
}
const server = createBridgeServer({
  connectorToken:process.env.BRIDGE_CONNECTOR_TOKEN,
  publicDir:path.join(root,'app/dist'),
  deviceRegistryPath:registryPath,
  trustProxy:true,
  uiLanguage:'zh-CN',
});
await server.listen(settings.port,'127.0.0.1');
fs.writeFileSync(path.join(state,'process.json'),JSON.stringify({pid:process.pid,startedAt:new Date().toISOString(),port:settings.port}));
console.log(`[bridge] Ready at http://127.0.0.1:${settings.port} (loopback only).`);
let child;
let stopped = false;
let retry;
let attempt = 0;
const log = value => {
  const file=path.join(state,'connector.log');
  if(fs.existsSync(file) && fs.statSync(file).size>5*1024*1024) {
    fs.rmSync(file+'.old',{force:true});fs.renameSync(file,file+'.old');
  }
  const line=new Date().toISOString()+' '+String(value).slice(0,1000);
  fs.appendFileSync(file,line+'\n');
  console.log('[connector] '+line);
};
const launch = () => {
  if(stopped) return;
  child = spawn(process.execPath,[path.join(root,'connector-child.mjs')],{
    cwd:path.join(root,'app'),windowsHide:true,stdio:['ignore','pipe','pipe','ipc'],
    env:{...process.env,
      BRIDGE_URL:`ws://127.0.0.1:${settings.port}/ws`,
      BRIDGE_DEVICE_ID:settings.deviceId,BRIDGE_DEVICE_LABEL:settings.deviceLabel,
      CODEX_CONNECTOR_MODE:'desktop',CODEX_BIN:settings.codexBin,
      CODEX_ALLOWED_ROOTS:settings.allowedRoots.join(path.delimiter),
      BRIDGE_INCLUDE_ARCHIVED:'1',CODEX_NETWORK_ACCESS:'0',CODEX_ALLOW_FULL_ACCESS:'0',CODEX_ALLOW_ANY_FILE_DOWNLOAD:'0',
      BRIDGE_SESSION_MODEL_SETTINGS_FILE:path.join(state,'session-model-settings.json'),
      BRIDGE_MESSAGE_QUEUE_FILE:path.join(state,'message-queue.enc.json'),
    },
  });
  child.stdout.on('data',data => log(data.toString().trim()));
  child.stderr.on('data',data => log(data.toString().trim()));
  child.on('error',error => log(error.code || error.message));
  child.on('exit',code => {
    log('connector exit '+code);
    if (!stopped) retry=setTimeout(launch,Math.min(30000,1000*2**Math.min(attempt++,5)));
  });
};
launch();
let shuttingDown;
const shutdown = () => shuttingDown ??= (async () => {
  stopped=true;
  console.log('[bridge] Stopping the bridge and connector...');
  clearTimeout(retry);clearInterval(controlTimer);
  if (child && child.exitCode===null) {
    try { child.send({type:'shutdown'}); } catch {}
    await Promise.race([new Promise(resolve=>child.once('exit',resolve)),new Promise(resolve=>setTimeout(resolve,5000))]);
    if (child.exitCode===null) child.kill();
  }
  await server.close();
  fs.rmSync(path.join(state,'process.json'),{force:true});
  fs.rmSync(path.join(state,'stop.request'),{force:true});
  console.log('[bridge] Stopped. Codex Desktop and its tasks are unchanged.');
  process.exit(0);
})();
const controlTimer = setInterval(()=>{if(fs.existsSync(path.join(state,'stop.request')))void shutdown();},1000);
process.on('SIGINT',shutdown);process.on('SIGTERM',shutdown);

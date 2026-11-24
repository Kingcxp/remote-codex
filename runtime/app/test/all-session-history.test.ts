import assert from 'node:assert/strict';
import test from 'node:test';
import { CodexAppServer } from '../src/connector/codex-app-server.js';

test('all history includes every provider, later pages and explicitly enabled archives without duplicates', async () => {
  const app = new CodexAppServer({includeArchivedSessions:true});
  app.ensureStarted = async () => {};
  const calls: any[] = [];
  app.rpcRaw = async <T>(_method: string, params: any) => {
    calls.push(params);
    assert.deepEqual(params.modelProviders, []);
    assert.deepEqual(params.sourceKinds, []);
    return (params.archived ? {data:[{id:'archived',name:'old'},{id:'recent'}]}
      : params.cursor ? {data:[{id:'older',name:'second page'}]}
      : {data:[{id:'recent',name:'current'}],nextCursor:'page-two'}) as T;
  };
  const rows = await app.listSessions();
  assert.deepEqual(rows.map(row => row.id), ['recent','older','archived']);
  assert.deepEqual(rows.map(row => row.archived), [false,false,true]);
  assert.equal(calls.length, 3);
  assert.equal(calls[1].cursor, 'page-two');
});

test('a repeated history cursor fails explicitly instead of looping or returning an incomplete list', async () => {
  const app = new CodexAppServer();
  app.ensureStarted = async () => {};
  let calls = 0;
  app.rpcRaw = async <T>() => { calls++; return {data:[],nextCursor:'repeated'} as T; };
  await assert.rejects(app.listSessions(), /thread_list_pagination_failed/);
  assert.equal(calls,2);
});

import { createHandler } from './index.ts';
const config = {url:'https://example.supabase.co',serviceKey:'internal-secret',workerSecret:'s'.repeat(48)};
function request(body: unknown, secret = config.workerSecret) {
  return new Request('https://example.test', {method:'POST', headers:{authorization:`Bearer ${secret}`},body:JSON.stringify(body)});
}
function assert(value: unknown) { if (!value) throw new Error('Assertion failed'); }
Deno.test('unauthenticated and unknown requests cannot call the database', async () => {
  let calls=0;
  const handler=createHandler(config, (()=>{calls++;throw new Error();}) as typeof fetch);
  assert((await handler(request({worker:'server',action:'claim'},'wrong'))).status===401);
  assert((await handler(request({worker:'server',action:'arbitrary_rpc'}))).status===400);
  assert(calls===0);
});
Deno.test('claim uses only the whitelisted RPC and server credentials', async () => {
  const handler=createHandler(config, (async (url, init)=>{
    assert(String(url).endsWith('/rest/v1/rpc/claim_dwts_work'));
    assert(JSON.parse(String(init?.body)).p_worker==='server');
    return Response.json({run_id:null});
  }) as typeof fetch);
  assert((await handler(request({worker:'server',action:'claim'}))).status===200);
});
Deno.test('expired leases are distinguishable and errors redact credentials', async () => {
  const handler=createHandler(config, (async ()=>Response.json({message:'Run lease expired '+config.serviceKey},{status:400})) as typeof fetch);
  const result=await handler(request({worker:'server',action:'heartbeat'}));
  assert(result.status===409);
  assert(!(await result.text()).includes(config.serviceKey));
});
Deno.test('preview validates week and malformed result is rejected', async () => {
  const handler=createHandler(config);
  assert((await handler(request({worker:'server',action:'preview',week:0,mode:'photos'}))).status===400);
  assert((await handler(request({worker:'server',action:'report',run_id:'bad',result:{}}))).status===400);
});

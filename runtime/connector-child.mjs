let stopping=false;
const requestShutdown=()=>{
  if(stopping)return;
  stopping=true;
  if(!process.emit('SIGTERM'))process.exit(0);
};
process.on('message',message=>{if(message?.type==='shutdown')requestShutdown();});
process.once('disconnect',requestShutdown);
await import('./app/build/connector/index.js');

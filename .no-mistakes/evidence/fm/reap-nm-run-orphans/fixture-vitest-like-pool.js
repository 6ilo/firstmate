// vitest-like pool: parent forks N workers, then exits so workers go to pid 1
const { fork } = require('child_process');
if (process.argv[2] === 'worker') { process.title = 'node (vitest ' + process.argv[3] + ')'; setInterval(()=>{}, 1e6); }
else { for (let i=1;i<=2;i++){ const c=fork(__filename,['worker',String(i)],{detached:true,stdio:'ignore'}); c.unref(); console.log(c.pid);} process.exit(0); }

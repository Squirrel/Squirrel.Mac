
var exec = require('child_process').exec;

exec('./SquirrelApp -releasify file.zip -version 0.0.143 -remote-path https://localhost/', { shell:'/bin/bash' }, function(error, stdout, stderr) {
  if (error) {
    console.log(error);
  }
  console.log(stdout);
  console.log(stderr);
});


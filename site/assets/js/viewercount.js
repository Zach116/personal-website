const APIEndpoint = 'https://vs50hsake9.execute-api.us-east-1.amazonaws.com/serverless-lambda-stage/db-connection';

(async function counter_fn() {
  var counter = document.getElementById("counter");
  let response = await fetch(APIEndpoint, {method: 'GET'});
  let data = await response.json();
  
  counter.innerHTML = data;
})();

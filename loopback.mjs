// Preloaded into the Kaneo API (node --import). Upstream's server listens on port 1337 on every
// interface; in a Cloudron container that would let other containers on the app network reach the
// API directly, bypassing nginx. Bind it to the loopback interface instead.
import net from "node:net";

const PORT = 1337;
const listen = net.Server.prototype.listen;

net.Server.prototype.listen = function (...args) {
  const [first, second] = args;
  if (first !== null && typeof first === "object" && Number(first.port) === PORT && !first.host) {
    args[0] = { ...first, host: "127.0.0.1" };
  } else if (Number(first) === PORT && (second === undefined || second === null || typeof second === "function")) {
    if (typeof second === "function") args.splice(1, 0, "127.0.0.1");
    else args[1] = "127.0.0.1";
  }
  return listen.apply(this, args);
};

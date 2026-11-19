// Purpose: Mutable counters and serializable stats snapshot.
/// Mutable counters shared by the proxy and transport layers.
class ProxyStats {
  int total = 0;
  int active = 0;
  int ws = 0;
  int h2 = 0;
  int h2Tcp = 0;
  int h2Req = 0;
  int h2Err = 0;
  int tcpFallback = 0;
  int cf = 0;
  int front = 0;
  int bad = 0;
  int masked = 0;
  int errors = 0;
  int poolHits = 0;
  int poolMisses = 0;
  int cfPoolHits = 0;
  int cfPoolMisses = 0;
  int bytesUp = 0;
  int bytesDown = 0;

  StatsSnapshot snapshot() => StatsSnapshot(
        total: total,
        active: active,
        ws: ws,
        h2: h2,
        h2Tcp: h2Tcp,
        h2Req: h2Req,
        h2Err: h2Err,
        tcpFallback: tcpFallback,
        cf: cf,
        front: front,
        bad: bad,
        masked: masked,
        errors: errors,
        poolHits: poolHits,
        poolMisses: poolMisses,
        cfPoolHits: cfPoolHits,
        cfPoolMisses: cfPoolMisses,
        bytesUp: bytesUp,
        bytesDown: bytesDown,
      );
}

class StatsSnapshot {
  const StatsSnapshot({
    required this.total,
    required this.active,
    required this.ws,
    required this.h2,
    required this.h2Tcp,
    required this.h2Req,
    required this.h2Err,
    required this.tcpFallback,
    required this.cf,
    required this.front,
    required this.bad,
    required this.masked,
    required this.errors,
    required this.poolHits,
    required this.poolMisses,
    required this.cfPoolHits,
    required this.cfPoolMisses,
    required this.bytesUp,
    required this.bytesDown,
  });

  final int total;
  final int active;
  final int ws;
  final int h2;
  final int h2Tcp;
  final int h2Req;
  final int h2Err;
  final int tcpFallback;
  final int cf;
  final int front;
  final int bad;
  final int masked;
  final int errors;
  final int poolHits;
  final int poolMisses;
  final int cfPoolHits;
  final int cfPoolMisses;
  final int bytesUp;
  final int bytesDown;

  Map<String, Object> toJson() => {
        'total': total,
        'active': active,
        'ws': ws,
        'h2': h2,
        'h2Tcp': h2Tcp,
        'h2Req': h2Req,
        'h2Err': h2Err,
        'tcpFallback': tcpFallback,
        'cf': cf,
        'front': front,
        'bad': bad,
        'masked': masked,
        'errors': errors,
        'pool': {'hits': poolHits, 'misses': poolMisses},
        'cfPool': {'hits': cfPoolHits, 'misses': cfPoolMisses},
        'bytesUp': bytesUp,
        'bytesDown': bytesDown,
      };
}

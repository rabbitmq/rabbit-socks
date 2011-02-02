
if (!'io' in this) {
    this.io = {};
}

(function(){
     var encode_message = function(props, msg) {
	 var enc_props;
	 if (props === undefined || props === null) {
	     enc_props = '';
	 } else {
	     enc_props = JSON.stringify(props);
	 }

	 return ("" + enc_props.length + " " + enc_props +
		 " " + msg.length + " " + msg);
     };

     var getnumber = function(offset, data) {
	 var str = data.substr(offset, 11);
	 var nr = str.substring(0, str.indexOf(' '));
	 return nr;
     };

     var decode_message = function(raw_data) {
	 var pos = 0;
	 var pl = getnumber(pos, raw_data);
	 pos += pl.length + 1;
	 var raw_props = raw_data.substring(pos, pos + Number(pl));
	 pos += Number(pl) + 1;
	 var ml = getnumber(pos, raw_data);
	 pos += ml.length + 1;
	 var msg = raw_data.substring(pos, pos + Number(ml));
	 var properties = undefined;
	 if (raw_props.length > 0) {
	     properties = JSON.parse(raw_props);
	 }
	 return {"properties": properties, "message": msg};
     };

     io.RabbitIO = function (socket) {
	 var that = this;
	 this.socket = socket;
	 this.state = 'new';
	 this.socket.on('connect', function(){
			    that._state_change(['connecting', 'connected'],
					       'connected');
			    that._try_flush_egress();
			});
	 this.socket.on('message', function(message){
			    that._deliver_message(message);
			});
	 this.socket.on('disconnect', function() {
			    if (that._state_change(['disconnecting'],
					       'new')) {
				// ok
			    } else {
				that.socket.connect();
			    }
			});
	 this.egress_buffer = [];
	 this.subscriptions = {};
     };

     io.RabbitIO.prototype = {
	 '_state_change': function(from, to) {
	     if (from.indexOf(this.state) != -1) {
		 this.state = to;
		 return true;
	     }
	     return false;
	 },
	 'connect': function() {
	     if (this._state_change(['new'], 'connecting')) {
		 this.socket.connect();
	     }
	 },
	 'disconnect': function() {
	     if (this._state_change(['connecting', 'connected'],
				    'disconnecting')) {
		 this.socket.disconnect();
	     }
	 },
	 '_deliver_message': function(raw_message) {
	     var o = decode_message(raw_message);
	     var channel = o.properties.channel;
	     if (channel in this.subscriptions) {
		 this.subscriptions[channel](o.message, o.properties);
	     } else {
		 // drop message.
	     }
	 },
	 '_try_flush_egress': function() {
	     if (this.state === 'connected') {
		 while (this.egress_buffer.length > 0) {
		     var raw_message = this.egress_buffer.shift();
		     this.socket.send(raw_message);
		 }
	     }
	 },
	 'publish': function(token, message) {
	     var raw_message = encode_message({'channel': token}, message);
	     this.egress_buffer.push(raw_message);
	     this._try_flush_egress();
	 },
	 'subscribe': function(token, callback) {
	     this.subscriptions[token] = callback;
	 }
     };
 })();

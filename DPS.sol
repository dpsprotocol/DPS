pragma solidity ^0.4.17;

import "github.com/Arachnid/solidity-stringutils/strings.sol";

/*
 *    Library with utilities to manage routing keys and binding keys
 */
library routingUtils {

    // Checks if the given Routing Key is valid
    // Allowed char are alphanumerical ones plus '-' plus
    // Routing Keys allow the use of special chars '*' and '#'
    function isValidRoutingKey(string str) public returns (bool) {
        var validChars = "abcdefghijklmnopqrstuvwxyz0123456789-*#";
        bool valid;
        uint countStar = 0;
        if (bytes(str).length == 0)
            return false;
        for (uint i = 0; i < bytes(str).length; i++) {
            for (uint j = 0; j < bytes(validChars).length; j++) {
                valid = false;
                if (bytes(str)[i] == bytes(validChars)[j]) {
                    if (bytes(str)[i] == "*")
                        countStar++;
                    if (countStar == 2) return false;                                                                // Allows only one *
                    valid = true;
                    break;
                }
            }
            if (!valid) return false;        
        }
        return true;
    }

    // Checks if the given Bining Key is valid
    // Allowed char are alphanumerical ones plus '-'
    function isValidBindingKey(string str) public returns (bool) {
        var validChars = "abcdefghijklmnopqrstuvwxyz0123456789-";
        bool valid;
        if (bytes(str).length == 0)
            return false;
        for (uint i = 0; i < bytes(str).length; i++) {
            for (uint j = 0; j < bytes(validChars).length; j++) {
                valid = false;
                if (bytes(str)[i] == bytes(validChars)[j]) {
                    valid = true;
                    break;
                }
            }
            if (!valid) return false;        
        }
        return true;
    }

    // Checks the presence of a given char in a given string
    function hasChar(string str, string char) public returns (bool) {
        for (uint i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(char)[0])
                return true;        
        }
        return false;
    }

}

/*
 *    Contract for ownership management
 */
contract owned {
    address public owner;

    function owned() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require (msg.sender == owner);
        _;
    }

    function transferOwnership(address newOwner) onlyOwner {
        owner = newOwner;
    }
}


/*
 *    This contract represents the Exchange entity
 */
contract Exchange is owned {

    mapping(string => address[]) bindings;
    mapping(string => address[]) bindingRequests;
	address[] publishers;
    address[] publishRequests;
    string[] bindingKeys;
	address[] validBindings;
	address[] _validBindings;

    using strings for *;
    
    // Constructor
    function Exchange() {
    }
    
    modifier onlyPublisher() {
        bool addressExists;
        addressExists = false;
        for (uint i = 0; i < publishers.length; i++) {
            if (publishers[i] == msg.sender) {
                addressExists = true;
                break;
            }
        }
        require(addressExists);
        _;
    }

    // The owner of the smart contract can bind Exchanges to Queues specifying a valid Binding Key
    // The function calls for a method on the given Queue because binding must be approved by the Queue itself
    // While waiting the approval, the Exchange stores the binding in the bindingRequest array
    function requestBindingToQueue(address queueAddress, string bindingKey) public onlyOwner {
        bindingRequests[bindingKey].push(queueAddress);
        Queue q = Queue(queueAddress);
        q.RequestBinding(bindingKey);
    }

    // If the Queue approves a binding requests, it will call this method
    function BindingApproved(string bindingKey) public returns (bool) {
		bool found;
		found = false;
        for (uint i = 0; i < bindingRequests[bindingKey].length; i++) {                         // Find the binding of the pair (msg.sender, bindingKey)
            if (bindingRequests[bindingKey][i] == msg.sender) {
                delete bindingRequests[bindingKey][i];
				found = true;
            }
        }
		if(!found)                                                                                                         // Catch unauthorized Queue
			return false;
		for (i = 0; i < bindings[bindingKey].length; i++) {                                           // Catch existing binding
			if(bindings[bindingKey][i] == msg.sender)
				return false;
		}
        bindings[bindingKey].push(msg.sender);                                                         // If correct, push the binding
        bool existingBindingKey = false;
        for (i = 0; i < bindingKeys.length; i++) {                                                         // Check if the BK already exists
            if (strings.compare(strings.toSlice(bindingKeys[i]),
                strings.toSlice(bindingKey)) == 0) {
                    existingBindingKey = true;
                    break;
            }
        }
        if (!existingBindingKey)                                                                                    // A new BK will be added
            bindingKeys.push(bindingKey);
		return true;
    }

    // If the Queue disapproves a binding requests, it will call this method
	// A call by an unauthorized Queue will be ignored
    function BindingRejected(string bindingKey) public {
        for (uint i = 0; i < bindingRequests[bindingKey].length; i++) {
            if (bindingRequests[bindingKey][i] == msg.sender) {
                delete bindingRequests[bindingKey][i];
            }
        }
    }

    // Any unregistered account can submit a request to publish through the exchange
    function publishRequest() public {
        publishRequests.push(msg.sender);
    }

    // Adds a publisher for the exchange
    function addPublisher(address publisherAddress) public onlyOwner {
        for (uint i = 0; i < publishRequests.length; i++) {
            if (publishRequests[i] == publisherAddress) {
                delete publishRequests[i];
            }
        }
        publishers.push(publisherAddress);
        Publisher p = Publisher(publisherAddress);
        p.canPublishToExchange();
    }

    // Rejects a publisher for the exchange
    function rejectPublisher(address publisherAddress) public onlyOwner {
        for (uint i = 0; i < publishRequests.length; i++) {
            if (publishRequests[i] == publisherAddress) {
                delete publishRequests[i];
            }
        }
    }

    // Removes the publisher from the exchange
    function removePublisher(address publisherAddress) public onlyOwner {
        for (uint i = 0; i < publishers.length; i++) {
            if (publishers[i] == publisherAddress) {
                delete publishers[i];
            }
        }
        Publisher p = Publisher(publisherAddress);
        p.removeExchange();
    }

    // A publisher invokes it to send a message through the exchange
    // This is the main function to process the topic (Routing Key)
    // The function recognizes special chars:
    //   '*' allows 1+ valid chars
    //   '#' allows 1 valid char
    // Specifying only '*' as Routing Key you get the FANOUT mode
    // Other uses of special chars induct the TOPIC mode
    // Specyfying a Routing Key without any special character you get the DIRECT mode
    function sendToQueues(bytes data, string routingKey) public onlyPublisher {
        require(routingUtils.isValidRoutingKey(routingKey));
		bool valid;
        uint j;
        uint k;
        Queue q;
        address a;
        for (uint i = 0; i < bindingKeys.length; i++) {                                                            // for every registered BK ( bindingKeys is a []string )
            valid = false;
			if (!routingUtils.hasChar(routingKey, "*") &&															// catch the wrong matches
			    bytes(routingKey).length != bytes(routingKey).length) {
					valid = false;
					break;
				}
            for (j = 0; j < bytes(routingKey).length; j++) {												     // analize the RK
                if (bytes(routingKey)[j] == "*") {                                                                      // '*' special char recognized
                    for (k = 0; k < bindings[bindingKeys[i]].length; k++)                                    // export all addresses associated to the analized BK
                        validBindings.push(bindings[bindingKeys[i]][k]);										 // ( bindings is a mapping(string => address[]) )
                    break;                                                                                                           // skip to next BK
                }
                else if (bytes(routingKey)[j] == bytes(bindingKeys[i])[j] ||								 // same char or '#' recognized
						   bytes(routingKey)[j] == "#") {                                                              
								valid = true;
				}
                else {                                                                                                               // not registered BK
                    valid = false;
                    break;                                                                                                          // skip to next BK
                }
            }
            if (valid)                                                                                                               // if the check is ok
                for (k = 0; k < bindings[bindingKeys[i]].length; k++)                                      // export all addresses associated to that bk
                    validBindings.push(bindings[bindingKeys[i]][k]);										   // ( bindings is a mapping(string => address[]) )
        }
        for (i = 0; i < validBindings.length; i++) {                                                                 // send data to all bounded queues
            q = Queue(validBindings[i]);                                                                                 // identified by the RK
            q.appendData(data);
        }
        delete validBindings;
    }

}


/*
 *    This contract represents the Queue entity
 */
contract Queue is owned {

    mapping(string => address[]) bindings;
    mapping(string => address[]) bindingRequests;
    address[] subscriptionRequests;
    address[] subscribers;
    string[] public bindingKeys;
    bytes[] queueData;                                                                        // queuing items
    uint queueLevel;                                                                             // number of items in the queue

    // Constructor
    function Queue() {
        queueLevel = 0;
    }
    
    modifier onlyBoundExchange() {
        bool addressExists;
        addressExists = false;
        uint j;
        for (uint i = 0; i < bindingKeys.length; i++) {
            for (j = 0;j < bindings[bindingKeys[i]].length; j++) {
                if (bindings[bindingKeys[i]][j] == msg.sender) {
                    addressExists = true;
                    break;
                }
            }
            if (addressExists)
                break;
        }
        require(addressExists);
        _;
    }

    // This is a method exposed to allow Exchanges to ask for a binding
    function RequestBinding(string bindingKey) public {
        bindingRequests[bindingKey].push(msg.sender);
    }

    // An approved binding is registered and the relative exchange has to be informed
    function approveBinding(address exchangeAddress, string bindingKey) public onlyOwner {
        for (uint i = 0; i < bindingRequests[bindingKey].length; i++) {
            if (bindingRequests[bindingKey][i] == exchangeAddress) {
                delete bindingRequests[bindingKey][i];
            }
        }
        bindings[bindingKey].push(exchangeAddress);
        Exchange x = Exchange(exchangeAddress);
        x.BindingApproved(bindingKey);
        bindingKeys.push(bindingKey);
    }

    // A rejected binding has to be discarded and the relative exchange has to be informed
    function rejectBinding(address exchangeAddress, string bindingKey) public onlyOwner {
        for (uint i = 0; i < bindingRequests[bindingKey].length; i++) {
            if (bindingRequests[bindingKey][i] == exchangeAddress) {
                delete bindingRequests[bindingKey][i];
            }
        }
        Exchange x = Exchange(exchangeAddress);
        x.BindingRejected(bindingKey);
    }

    // Any unregistered account can submit a request to subscribe to the queue
    function requestSubscription() public {
        subscriptionRequests.push(msg.sender);
    }

    // Adds a subscriber for the queue
    function addSubscriber(address subscriberAddress) public onlyOwner {
        Subscriber sub;
        for (uint i = 0; i < subscriptionRequests.length; i++) {
            if (subscriptionRequests[i] == subscriberAddress) {
                delete subscriptionRequests[i];
                break;
            }
        }
        subscribers.push(subscriberAddress);
        sub = Subscriber(subscriberAddress);
        sub.subscribedToQueue();
    }

    // Rejects a subscriber for the queue
    function rejectSubscriber(address subscriberAddress) public onlyOwner {
        for (uint i = 0; i < subscriptionRequests.length; i++) {
            if (subscriptionRequests[i] == subscriberAddress) {
                delete subscriptionRequests[i];
                break;
            }
        }
    }

    // Removes the subscriber from the queue
    function removeSubscriber(address subscriberAddress) public onlyOwner {
        for (uint i = 0; i < subscribers.length; i++) {
            if (subscribers[i] == subscriberAddress) {
                delete subscribers[i];
                break;
            }
        }
        Subscriber sub = Subscriber(subscriberAddress);
        sub.unsubscribeToQueue();
    }

    // the method called by an Exchange which has to send data to the queue
	// In this implementation data will be delivered as soon as the queue receive them
	// The delivery process could be independent with respect to this method
    function appendData(bytes data) public onlyBoundExchange {
        queueData.push(data);
        queueLevel++;
		deliverData();                                                                                         // Immediate delivery
    }

    // The delivery of the queuing elements to the subscribers
    function deliverData() public onlyOwner {
        Subscriber sub;
        for (uint i; i < subscribers.length; i++) {
            sub = Subscriber(subscribers[i]);
            for (uint j; j < queueData.length; j++) {
                sub.consume(queueData[j]);
            }
        }
        cleanQueue();
    }

    // Cleaning of the queue
    function cleanQueue() public onlyOwner {
        delete queueData;
        queueLevel = 0;
    }

}


/*
 *    This contract represents the Publisher entity
 */
contract Publisher is owned {

    address[] publishToExchanges;                                                            // Exchanges accessible for the publisher
    address[] publishToExchangesRequests;                                              // Requests: Exchanges accessible for the publisher

	modifier onlyAvailableExchanges() {
        bool addressExists;
        addressExists = false;
        for (uint i = 0; i < publishToExchanges.length; i++) {
            if (publishToExchanges[i] == msg.sender) {
                addressExists = true;
                break;
            }
        }
        require(addressExists);
        _;
    }
	
	modifier onlyRequestedExchanges() {
        bool addressExists;
        addressExists = false;
        for (uint i = 0; i < publishToExchangesRequests.length; i++) {
            if (publishToExchangesRequests[i] == msg.sender) {
                addressExists = true;
                break;
            }
        }
        require(addressExists);
        _;
    }
	
    // a request to an Exchange for publishing through itself
    function publishToExchangeRequest(address exchangeAddress) public onlyOwner {
        bool found;
        found = false;
        for (uint i = 0; i < publishToExchanges.length; i++) {
            if (publishToExchanges[i] == exchangeAddress) {
                found = true;
                break;
            }
        }
        if (!found) {
			publishToExchangesRequests.push(exchangeAddress);
            Exchange x = Exchange(exchangeAddress);
            x.publishRequest();
        }
    }

    // a request to an Exchange for publishing through itself
    function publishToExchange(address exchangeAddress, bytes data, string routingKey) public {
        Exchange x = Exchange(exchangeAddress);
        x.sendToQueues(data, routingKey);
    }

    // method called by the Exchange to confirm the request for publishing through itslef
    function canPublishToExchange() public onlyRequestedExchanges {
        publishToExchanges.push(msg.sender);
		 for (uint i = 0; i < publishToExchangesRequests.length; i++) {
            if (publishToExchangesRequests[i] == msg.sender)
                delete publishToExchangesRequests[i];
        }
    }

    // method called by the Exchange to deny the access to itself for the Publisher
    function removeExchange() public onlyAvailableExchanges {
        for (uint i = 0; i < publishToExchanges.length; i++) {
            if (publishToExchanges[i] == msg.sender)
                delete publishToExchanges[i];
        }
    }

}


/*
 *    This contract represents the Subscriber entity
 */
contract Subscriber is owned {

    bytes[] public mem;                                                                                         // Received data
    address[] subscribedToQueues;
    address[] subscribedToQueuesRequests;

	modifier onlyAvailableQueues() {
        bool addressExists;
        addressExists = false;
        for (uint i = 0; i < subscribedToQueues.length; i++) {
            if (subscribedToQueues[i] == msg.sender) {
                addressExists = true;
                break;
            }
        }
        require(addressExists);
        _;
    }
	
	modifier onlyRequestedQueues() {
        bool addressExists;
        addressExists = false;
        for (uint i = 0; i < subscribedToQueuesRequests.length; i++) {
            if (subscribedToQueuesRequests[i] == msg.sender) {
                addressExists = true;
                break;
            }
        }
        require(addressExists);
        _;
    }	
	
    // method called by the Queue when sending data to the Subscriber
    function consume(bytes data) public onlyAvailableQueues{
        mem.push(data);
    }

    // a request to the Queue for subscribing to its data
    function subscribeToQueueRequest(address queueAddress) public onlyOwner {
        bool found;
        found = false;
        for (uint i = 0; i < subscribedToQueues.length; i++) {
            if (subscribedToQueues[i] == queueAddress) {
                found = true;
                break;
            }
        }
        if (!found) {
            subscribedToQueuesRequests.push(queueAddress);
			Queue q = Queue(queueAddress);
            q.requestSubscription();
        }
    }

    // a method called by the Queue to confirm the subscription to itself for the Subscriber
    function subscribedToQueue() public onlyRequestedQueues {
		for (uint i = 0; i < subscribedToQueuesRequests.length; i++) {
            if (subscribedToQueuesRequests[i] == msg.sender)
                delete subscribedToQueuesRequests[i];
        }
        subscribedToQueues.push(msg.sender);
    }

    // a method called by the Queue to unsubscribe the user to itself
    function unsubscribeToQueue() public onlyAvailableQueues {
        for (uint i = 0; i < subscribedToQueues.length; i++) {
            if (subscribedToQueues[i] == msg.sender)
                delete subscribedToQueues[i];
        }
    }

}

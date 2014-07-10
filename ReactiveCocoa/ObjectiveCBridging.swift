//
//  ObjectiveCBridging.swift
//  ReactiveCocoa
//
//  Created by Justin Spahr-Summers on 2014-07-02.
//  Copyright (c) 2014 GitHub, Inc. All rights reserved.
//

import Foundation

extension RACDisposable: Disposable {}
extension RACScheduler: Scheduler, RepeatableScheduler {
	func schedule(action: () -> ()) -> Disposable? {
		let disposable: RACDisposable? = self.schedule(action)
		return disposable
	}

	func scheduleAfter(date: NSDate, action: () -> ()) -> Disposable? {
		let disposable: RACDisposable? = self.after(date, schedule: action)
		return disposable
	}

	func scheduleAfter(date: NSDate, repeatingEvery: NSTimeInterval, withLeeway: NSTimeInterval, action: () -> ()) -> Disposable? {
		let disposable: RACDisposable? = self.after(date, repeatingEvery: repeatingEvery, withLeeway: withLeeway, schedule: action)
		return disposable
	}
}

extension RACScheduler: BridgedScheduler {
	func asRACScheduler() -> RACScheduler {
		return self
	}
}

extension ImmediateScheduler: BridgedScheduler {
	func asRACScheduler() -> RACScheduler {
		return RACScheduler.immediateScheduler()
	}
}

extension MainScheduler: BridgedScheduler {
	func asRACScheduler() -> RACScheduler {
		return RACScheduler.mainThreadScheduler()
	}
}

extension QueueScheduler: BridgedScheduler {
	func asRACScheduler() -> RACScheduler {
		return RACTargetQueueScheduler(name: nil, targetQueue: _queue)
	}
}

// FIXME: Do something better with this.
let emptyError = NSError(domain: "RACErrorDomain", code: 1, userInfo: nil)

extension RACSignal {
	/// Creates an Producer that will produce events by subscribing to the
	/// RACSignal.
	func asProducer() -> Producer<AnyObject?> {
		return Producer { consumer in
			let next = { (obj: AnyObject?) -> () in
				consumer.put(.Next(Box(obj)))
			}

			let error = { (maybeError: NSError?) -> () in
				if let e = maybeError {
					consumer.put(.Error(e))
				} else {
					consumer.put(.Error(emptyError))
				}
			}

			let completed = {
				consumer.put(.Completed)
			}

			let disposable: RACDisposable? = self.subscribeNext(next, error: error, completed: completed)
			consumer.disposable.addDisposable(disposable)
		}
	}

	/// Creates a Signal that will immediately subscribe to a RACSignal,
	/// and observe its latest value.
	///
	/// The signal must not generate an `error` event.
	func asSignalOfLatestValue(initialValue: AnyObject? = nil) -> Signal<AnyObject?> {
		let property = SignalingProperty(initialValue)
		asProducer().bindTo(property)

		return property
	}

	/// Creates a Promise that will subscribe to a RACSignal when started, and
	/// yield the signal's _last_ value (or the given default value, if none are
	/// sent) after it has completed successfully.
	func asPromiseOfLastValue(defaultValue: AnyObject? = nil) -> Promise<Result<AnyObject?>> {
		return Promise { sink in
			let next = { (obj: AnyObject?) -> () in
				sink.put(.Success(Box(obj)))
			}

			let error = { (maybeError: NSError?) -> () in
				if let e = maybeError {
					sink.put(Result.Error(e))
				} else {
					sink.put(Result.Error(emptyError))
				}
			}

			let completed = { () -> () in
				// This will only take effect if we didn't get a `Next` event.
				sink.put(.Success(Box(defaultValue)))
			}

			self.takeLast(1).subscribeNext(next, error: error, completed: completed)
			return ()
		}
	}
}

extension Producer {
	/// Creates a "cold" RACSignal that will produce events from the receiver
	/// upon each subscription.
	///
	/// evidence - Used to prove to the typechecker that the receiver is
	///            a stream of objects. Simply pass in the `identity` function.
	func asDeferredRACSignal<U: AnyObject>(evidence: Producer<T> -> Producer<U?>) -> RACSignal {
		return RACSignal.createSignal { subscriber in
			let selfDisposable = evidence(self).produce { event in
				switch event {
				case let .Next(obj):
					subscriber.sendNext(obj)

				case let .Error(error):
					subscriber.sendError(error)

				case let .Completed:
					subscriber.sendCompleted()
				}
			}

			return RACDisposable {
				selfDisposable.dispose()
			}
		}
	}
}

extension Signal {
	/// Creates a "hot" RACSignal that will forward values from the receiver.
	///
	/// evidence - Used to prove to the typechecker that the receiver is
	///            a stream of objects. Simply pass in the `identity` function.
	///
	/// Returns an infinite signal that will send the observable's current
	/// value, then all changes thereafter. The signal will never complete or
	/// error, so it must be disposed manually.
	func asInfiniteRACSignal<U: AnyObject>(evidence: Signal<T> -> Signal<U?>) -> RACSignal {
		return RACSignal.createSignal { subscriber in
			evidence(self).observe { value in
				subscriber.sendNext(value)
			}

			return nil
		}
	}
}

extension Promise {
	/// Creates a "warm" RACSignal that will start the promise upon the first
	/// subscription, and share the result with all subscribers.
	///
	/// evidence - Used to prove to the typechecker that the receiver will
	///            produce an object. Simply pass in the `identity` function.
	func asReplayedRACSignal<U: AnyObject>(evidence: Promise<T> -> Promise<U>) -> RACSignal {
		return RACSignal.createSignal { subscriber in
			evidence(self).start().observe { maybeResult in
				if let result = maybeResult {
					subscriber.sendNext(result)
					subscriber.sendCompleted()
				}
			}

			return nil
		}
	}
}

extension RACCommand {
	/// Creates an Action that will execute the command, then forward the last
	/// value generated by the execution.
	func asAction() -> Action<AnyObject?, AnyObject?> {
		let enabled: Signal<Bool> = self.enabled
			.asSignalOfLatestValue()
			.map { obj in
				if let num = obj as? NSNumber {
					return num.boolValue
				} else {
					return true
				}
			}

		return Action(enabledIf: enabled) { input in
			return RACSignal
				.defer { self.execute(input) }
				.asPromiseOfLastValue()
		}
	}
}

extension Action {
	/// Creates a RACCommand that will execute the Action.
	///
	/// evidence - Used to prove to the typechecker that the receiver accepts
	///            and produces objects. Simply pass in the `identity` function.
	func asCommand<U: AnyObject>(evidence: Action<I, O> -> Action<AnyObject?, U?>) -> RACCommand {
		let enabled = self.enabled
			.map { $0 as NSNumber? }
			.asInfiniteRACSignal(identity)

		return RACCommand(enabled: enabled) { input in
			return RACSignal.createSignal { subscriber in
				evidence(self).execute(input).observe { maybeResult in
					if !maybeResult {
						return
					}

					switch maybeResult! {
					case let .Success(obj):
						subscriber.sendNext(obj)
						subscriber.sendCompleted()

					case let .Error(error):
						subscriber.sendError(error)
					}
				}

				return nil
			}
		}
	}
}

// These definitions work around a weird bug where the `RACEvent.value` property
// is considered to be a Swift function on OS X and a Swift property on iOS.
func _getValue(v: AnyObject?) -> AnyObject? {
	return v
}

func _getValue(f: () -> AnyObject?) -> AnyObject? {
	return f()
}

extension RACEvent {
	/// Creates an Event from the RACEvent.
	func asEvent() -> Event<AnyObject?> {
		switch eventType {
		case RACEventType.Next:
			let obj: AnyObject? = _getValue(value)
			return .Next(Box(obj))

		case RACEventType.Error:
			return .Error(error)

		case RACEventType.Completed:
			return .Completed
		}
	}
}

extension Event {
	/// Creates a RACEvent from the Event.
	///
	/// evidence - Used to prove to the typechecker that the event can contain
	///            an object. Simply pass in the `identity` function.
	func asRACEvent<U: AnyObject>(evidence: Event<T> -> Event<U>) -> RACEvent {
		switch evidence(self) {
		case let .Next(obj):
			return RACEvent(value: obj)

		case let .Error(error):
			return RACEvent(error: error)

		case let .Completed:
			return RACEvent.completedEvent()
		}
	}
}
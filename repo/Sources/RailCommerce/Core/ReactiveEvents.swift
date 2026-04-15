import Foundation

// MARK: - Messaging events

/// Events published on `MessagingService.events`.
public enum MessagingEvent: Equatable {
    case messageEnqueued(String)    // message id
    case queueDrained(Int)          // number of messages delivered
}

// MARK: - Checkout events

/// Events published on `CheckoutService.events`.
public enum CheckoutEvent: Equatable {
    case orderSubmitted(String)     // order id
    case orderVerified(String)      // order id
}

// MARK: - After-sales events

/// Events published on `AfterSalesService.events`.
public enum AfterSalesEvent: Equatable {
    case requestOpened(String)      // request id
    case requestResolved(String, AfterSalesStatus)
}

// MARK: - Seat inventory events

/// Events published on `SeatInventoryService.events`.
public enum SeatInventoryEvent: Equatable {
    case seatReserved(String, String)   // trainId, seatNumber
    case seatConfirmed(String, String)
    case seatReleased(String, String)
}

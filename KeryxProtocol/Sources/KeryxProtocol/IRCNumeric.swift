import Foundation

/// Common IRC numeric reply codes. Only the codes the client acts on are
/// enumerated; unknown numerics are still parsed and surfaced as raw strings
/// via `IRCMessage.command`.
public enum IRCNumeric: Int, Sendable {
    // Registration / welcome
    case welcome = 1            // RPL_WELCOME
    case yourHost = 2           // RPL_YOURHOST
    case created = 3            // RPL_CREATED
    case myInfo = 4             // RPL_MYINFO
    case iSupport = 5           // RPL_ISUPPORT

    // User / channel info
    case umodeIs = 221          // RPL_UMODEIS
    case away = 301             // RPL_AWAY
    case unaway = 305           // RPL_UNAWAY
    case nowAway = 306          // RPL_NOWAWAY
    case whoisUser = 311        // RPL_WHOISUSER
    case whoisServer = 312      // RPL_WHOISSERVER
    case whoisIdle = 317        // RPL_WHOISIDLE
    case endOfWhois = 318       // RPL_ENDOFWHOIS
    case whoisChannels = 319    // RPL_WHOISCHANNELS
    case whoisOperator = 313    // RPL_WHOISOPERATOR
    case whowasUser = 314       // RPL_WHOWASUSER
    case channelModeIs = 324    // RPL_CHANNELMODEIS
    case creationTime = 329     // RPL_CREATIONTIME
    case whoisAccount = 330     // RPL_WHOISACCOUNT
    case noTopic = 331          // RPL_NOTOPIC
    case whoisActually = 338    // RPL_WHOISACTUALLY
    case whoisCertFP = 276      // RPL_WHOISCERTFP
    case whoisSecure = 671      // RPL_WHOISSECURE
    case whoisHost = 378        // RPL_WHOISHOST
    case whoisModes = 379       // RPL_WHOISMODES
    case endOfWhowas = 369      // RPL_ENDOFWHOWAS
    case list = 322             // RPL_LIST
    case listEnd = 323          // RPL_LISTEND
    case topic = 332            // RPL_TOPIC
    case topicWhoTime = 333     // RPL_TOPICWHOTIME
    case whoisBot = 335         // RPL_WHOISBOT
    case inviting = 341         // RPL_INVITING
    case keyValue = 761         // RPL_KEYVALUE (metadata)
    case metadataSubOK = 770    // RPL_METADATASUBOK
    case metadataUnsubOK = 771  // RPL_METADATAUNSUBOK
    case metadataSubs = 772     // RPL_METADATASUBS
    case metadataSyncLater = 774 // RPL_METADATASYNCLATER
    case endOfWho = 315         // RPL_ENDOFWHO
    case whoReply = 352         // RPL_WHOREPLY
    case namReply = 353         // RPL_NAMREPLY
    case whoSpcRpl = 354        // RPL_WHOSPCRPL (WHOX)
    case endOfNames = 366       // RPL_ENDOFNAMES
    case inviteList = 346       // RPL_INVITELIST (+I)
    case endOfInviteList = 347  // RPL_ENDOFINVITELIST
    case exceptList = 348       // RPL_EXCEPTLIST (+e)
    case endOfExceptList = 349  // RPL_ENDOFEXCEPTLIST
    case banList = 367          // RPL_BANLIST (+b)
    case endOfBanList = 368     // RPL_ENDOFBANLIST
    case quietList = 728        // RPL_QUIETLIST (+q, Solanum and kin)
    case endOfQuietList = 729   // RPL_ENDOFQUIETLIST
    case motd = 372             // RPL_MOTD
    case motdStart = 375        // RPL_MOTDSTART
    case endOfMotd = 376        // RPL_ENDOFMOTD

    // SASL
    case loggedIn = 900         // RPL_LOGGEDIN
    case loggedOut = 901        // RPL_LOGGEDOUT
    case nickLocked = 902       // ERR_NICKLOCKED
    case saslSuccess = 903      // RPL_SASLSUCCESS
    case saslFail = 904         // ERR_SASLFAIL
    case saslTooLong = 905      // ERR_SASLTOOLONG
    case saslAborted = 906      // ERR_SASLABORTED
    case saslAlready = 907      // ERR_SASLALREADY
    case saslMechs = 908        // RPL_SASLMECHS

    // Errors the client reacts to during registration
    case noNicknameGiven = 431  // ERR_NONICKNAMEGIVEN
    case erroneousNick = 432    // ERR_ERRONEUSNICKNAME
    case noMotd = 422           // ERR_NOMOTD
    case nicknameInUse = 433    // ERR_NICKNAMEINUSE
    case noSuchNick = 401       // ERR_NOSUCHNICK
    case noSuchChannel = 403    // ERR_NOSUCHCHANNEL
    case cannotSendToChan = 404 // ERR_CANNOTSENDTOCHAN
    case unavailResource = 437  // ERR_UNAVAILRESOURCE
    case userNotInChannel = 441 // ERR_USERNOTINCHANNEL
    case notOnChannel = 442     // ERR_NOTONCHANNEL
    case channelIsFull = 471    // ERR_CHANNELISFULL
    case inviteOnlyChan = 473   // ERR_INVITEONLYCHAN
    case bannedFromChan = 474   // ERR_BANNEDFROMCHAN
    case badChannelKey = 475    // ERR_BADCHANNELKEY
    case needReggedNick = 477   // ERR_NEEDREGGEDNICK
    case chanOpPrivsNeeded = 482 // ERR_CHANOPRIVSNEEDED
    case monOnline = 730        // RPL_MONONLINE
    case monOffline = 731       // RPL_MONOFFLINE
    case monList = 732          // RPL_MONLIST
    case endOfMonList = 733     // RPL_ENDOFMONLIST
    case monListFull = 734      // ERR_MONLISTFULL
    case nickCollision = 436    // ERR_NICKCOLLISION

    /// `true` for the 900-range SASL completion codes that end authentication.
    public var endsSASL: Bool {
        switch self {
        case .saslSuccess, .saslFail, .saslTooLong, .saslAborted,
             .saslAlready, .nickLocked:
            return true
        default:
            return false
        }
    }
}

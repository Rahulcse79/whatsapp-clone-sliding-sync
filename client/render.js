/*
 * This file contains code to map data structures to actual HTML elements.
 * It is mostly functional and boring and it does not include any sliding sync specific data.
 * In other words, if you want to learn about sliding sync, this isn't the file to look at.
 */

const membershipChangeText = (ev) => {
    const prevContent = (ev.unsigned || {}).prev_content || {};
    const prevMembership = prevContent.membership || "leave";
    const nowMembership = ev.content.membership;
    if (nowMembership != prevMembership) {
        switch (nowMembership) {
            case "join":
                return ev.state_key + " joined the room";
            case "leave":
                return ev.state_key + " left the room";
            case "ban":
                return ev.sender + " banned " + ev.state_key + " from the room";
            case "invite":
                return ev.sender + " invited " + ev.state_key + " to the room";
            case "knock":
                return ev.state_key + " knocked on the room";
        }
    }
    if (nowMembership == prevMembership && nowMembership == "join") {
        // display name or avatar change
        if (prevContent.displayname !== ev.content.displayname) {
            return (
                ev.state_key + " set their name to " + ev.content.displayname
            );
        }
        if (prevContent.avatar_url !== ev.content.avatar_url) {
            return ev.state_key + " changed their profile picture";
        }
    }
    return ev.type + " event";
};

const textForEvent = (ev) => {
    let body = "";
    switch (ev.type) {
        case "m.room.message":
            body = ev.content.body;
            break;
        case "m.room.member":
            body = membershipChangeText(ev);
            break;
        case "m.reaction":
            body = "reacted with " + (ev.content["m.relates_to"] || {}).key;
            break;
        default:
            body = ev.type + " event";
            break;
    }
    return body;
};

const randomName = (i, long) => {
    if (i % 17 === 0) {
        return long
            ? "Ever have that feeling where you’re not sure if you’re awake or dreaming?"
            : "There is no spoon";
    } else if (i % 13 === 0) {
        return long
            ? "Choice is an illusion created between those with power and those without."
            : "Get Up Trinity";
    } else if (i % 11 === 0) {
        return long
            ? "That’s how it is with people. Nobody cares how it works as long as it works."
            : "I know kung fu";
    } else if (i % 7 === 0) {
        return long
            ? "The body cannot live without the mind."
            : "Free your mind";
    } else if (i % 5 === 0) {
        return long
            ? "Perhaps we are asking the wrong questions…"
            : "Agent Smith";
    } else if (i % 3 === 0) {
        return long
            ? "You've been living in a dream world, Neo."
            : "Mr Anderson";
    } else {
        return long ? "Mr. Wizard, get me the hell out of here! " : "Morpheus";
    }
};

const zeroPad = (n) => {
    if (n < 10) {
        return "0" + n;
    }
    return n;
};

const formatTimestamp = (originServerTs) => {
    const d = new Date(originServerTs);
    return zeroPad(d.getHours()) + ":" + zeroPad(d.getMinutes());
};

const formatTimestampShort = (originServerTs) => {
    const d = new Date(originServerTs);
    const now = new Date();
    const isToday = d.toDateString() === now.toDateString();
    const yesterday = new Date(now);
    yesterday.setDate(yesterday.getDate() - 1);
    const isYesterday = d.toDateString() === yesterday.toDateString();
    if (isToday) {
        return zeroPad(d.getHours()) + ":" + zeroPad(d.getMinutes());
    } else if (isYesterday) {
        return "Yesterday";
    } else {
        return zeroPad(d.getDate()) + "/" + zeroPad(d.getMonth() + 1) + "/" + d.getFullYear();
    }
};

const mxcToUrl = (syncv2ServerUrl, mxc) => {
    const path = mxc.substr("mxc://".length);
    if (!path) {
        return;
    }
    return `${syncv2ServerUrl}/_matrix/media/r0/thumbnail/${path}?width=64&height=64&method=crop`;
};

export const renderRoomHeader = (room, syncv2ServerUrl) => {
    document.getElementById("selectedroomname").textContent =
        room.name || room.room_id;
    if (room.avatar) {
        document.getElementById("selectedroomavatar").src =
            mxcToUrl(syncv2ServerUrl, room.avatar) || "/client/placeholder.svg";
    } else {
        document.getElementById("selectedroomavatar").src =
            "/client/placeholder.svg";
    }
    if (room.topic) {
        document.getElementById("selectedroomtopic").textContent = room.topic;
    } else {
        document.getElementById("selectedroomtopic").textContent = "online";
    }
};

export const renderEvent = (eventIdKey, ev, selfUserId) => {
    const template = document.getElementById("messagetemplate");
    const msgCell = template.content.firstElementChild.cloneNode(true);
    msgCell.setAttribute("id", eventIdKey);
    // Mark sent vs received
    if (selfUserId && ev.sender === selfUserId) {
        msgCell.classList.add("wa-msg-sent");
    }
    msgCell.getElementsByClassName("msgsender")[0].textContent = ev.sender;
    msgCell.getElementsByClassName("msgtimestamp")[0].textContent =
        formatTimestamp(ev.origin_server_ts);
    let body = textForEvent(ev);
    msgCell.getElementsByClassName("msgcontent")[0].textContent = body;
    return msgCell;
};

/**
 * Render a room cell for the room list.
 * @param {Element} roomCell The DOM element to put the details into. The cell must be already initialised with `roomCellTemplate`.
 * @param {object} room The room data model, which can be null to indicate a placeholder.
 */
export const renderRoomCell = (
    roomCell,
    room,
    index,
    isHighlighted,
    syncv2ServerUrl
) => {
    // if this child is a placeholder and it was previously a placeholder then do nothing.
    if (!room && roomCell.getAttribute("x-placeholder") === "yep") {
        return;
    }
    const roomNameSpan = roomCell.getElementsByClassName("roomname")[0];
    const roomContentSpan = roomCell.getElementsByClassName("roomcontent")[0];
    const roomSenderSpan = roomCell.getElementsByClassName("roomsender")[0];
    const roomTimestampSpan =
        roomCell.getElementsByClassName("roomtimestamp")[0];
    const unreadCountSpan = roomCell.getElementsByClassName("unreadcount")[0];

    // remove previous unread counts
    unreadCountSpan.textContent = "";
    unreadCountSpan.classList.remove("unreadcountnotify");
    unreadCountSpan.classList.remove("unreadcounthighlight");

    if (!room) {
        // make a placeholder
        roomNameSpan.textContent = randomName(index, false);
        roomNameSpan.style = "background: #e0e0e0; color: #e0e0e0;";
        roomContentSpan.textContent = randomName(index, true);
        roomContentSpan.style = "background: #e0e0e0; color: #e0e0e0;";
        roomSenderSpan.textContent = "";
        roomTimestampSpan.textContent = "";
        roomCell.getElementsByClassName("roomavatar")[0].src =
            "/client/placeholder.svg";
        roomCell.style = "";
        roomCell.setAttribute("x-placeholder", "yep");
        return;
    }

    roomCell.removeAttribute("x-placeholder"); // in case this was previously a placeholder
    roomCell.style = "";
    roomCell.classList.remove("roomcell-selected");
    roomCell.classList.remove("roomcell-unread");
    roomNameSpan.textContent = room.name || room.room_id;
    roomNameSpan.style = "";
    roomContentSpan.style = "";
    if (room.avatar) {
        roomCell.getElementsByClassName("roomavatar")[0].src =
            mxcToUrl(syncv2ServerUrl, room.avatar) || "/client/placeholder.svg";
    } else {
        roomCell.getElementsByClassName("roomavatar")[0].src =
            "/client/placeholder.svg";
    }
    if (isHighlighted) {
        roomCell.classList.add("roomcell-selected");
    }
    if (room.highlight_count > 0) {
        // use the notification count instead to avoid counts dropping down. This matches ele-web
        unreadCountSpan.textContent = room.notification_count + "";
        unreadCountSpan.classList.add("unreadcounthighlight");
        roomCell.classList.add("roomcell-unread");
    } else if (room.notification_count > 0) {
        unreadCountSpan.textContent = room.notification_count + "";
        unreadCountSpan.classList.add("unreadcountnotify");
        roomCell.classList.add("roomcell-unread");
    } else {
        unreadCountSpan.textContent = "";
    }

    if (room.obsolete) {
        roomContentSpan.textContent = "";
        roomSenderSpan.textContent = room.obsolete;
    } else if (room.timeline && room.timeline.length > 0) {
        const mostRecentEvent = room.timeline[room.timeline.length - 1];
        const senderShort = mostRecentEvent.sender.split(":")[0].replace("@","");
        roomSenderSpan.textContent = senderShort + ": ";

        roomTimestampSpan.textContent = formatTimestampShort(
            mostRecentEvent.origin_server_ts
        );

        const body = textForEvent(mostRecentEvent);
        if (mostRecentEvent.type === "m.room.member") {
            roomContentSpan.textContent = "";
            roomSenderSpan.textContent = body;
        } else {
            roomContentSpan.textContent = body;
        }
    } else {
        roomContentSpan.textContent = "";
    }
};

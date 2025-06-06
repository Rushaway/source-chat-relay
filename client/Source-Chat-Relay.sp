#include <sourcemod>
#include <socket>
#tryinclude <morecolors> // Morecolors defines a max buffer as well as bytebuffer but bytebuffer does if defined check
#if !defined _colors_included
	#include <multicolors>
#endif
#include <bytebuffer>

#pragma semicolon 1

#define MAX_EVENT_NAME_LENGTH 128
#define MAX_COMMAND_LENGTH 512

#pragma newdecls required

char g_sHostname[64];
char g_sHost[64] = "127.0.0.1";
char g_sToken[64];
char g_sPrefix[8];

int g_iPort = 57452;
int g_iFlag;

bool g_bFlag;
bool g_bSocketErrorLogged;

// Core convars
ConVar g_cHost;
ConVar g_cPort;
ConVar g_cPrefix;
ConVar g_cFlag;
ConVar g_cHostname;
ConVar g_cTimeStamp;
ConVar g_cAuthIdType;
ConVar g_cDebug;

// Event convars
ConVar g_cPlayerEvent;
ConVar g_cBotPlayerEvent;
ConVar g_cMapEvent;

// Socket connection handle
Handle g_hSocket;

// Forward handles
Handle g_hMessageSendForward;
Handle g_hMessageReceiveForward;
Handle g_hEventSendForward;
Handle g_hEventReceiveForward;

EngineVersion g_evEngine;

enum MessageType
{
	MessageInvalid = 0,
	MessageAuthenticate,
	MessageAuthenticateResponse,
	MessageChat,
	MessageEvent,
	MessageTypeCount,
}

enum AuthenticateResponse
{
	AuthenticateInvalid = 0,
	AuthenticateSuccess,
	AuthenticateDenied,
	AuthenticateResponseCount,
}

enum IdentificationType
{
	IdentificationInvalid = 0,
	IdentificationSteam,
	IdentificationDiscord,
	IdentificationTypeCount,
}

/**
 * Base message structure
 * 
 * @note The type is declared on every derived message type
 * 
 * @field type - byte - The message type (enum MessageType)
 * @field EntityName - string - Entity name that's sending the message
 */
methodmap BaseMessage < ByteBuffer
{
	public BaseMessage()
	{
		return view_as<BaseMessage>(CreateByteBuffer());
	}

	property MessageType Type
	{
		public get()
		{
			MessageType tByte = view_as<MessageType>(this.ReadByte());

			return tByte >= MessageTypeCount ? MessageInvalid : tByte;
		}
	}

	public int ReadDiscardString()
	{
		char cByte;

		for(int i = 0; i < MAX_BUFFER_LENGTH; i++) {
			cByte = this.ReadByte();
			
			if(cByte == '\0') {
				return i + 1;
			}
		}
		
		return MAX_BUFFER_LENGTH;
	}

	public void DataCursor()
	{
		// Skip the message type field
		this.Cursor = 1;

		this.ReadDiscardString();
	}

	public void GetEntityName(char[] sEntityName, int iSize)
	{
		// Skip the message type field
		this.Cursor = 1;

		this.ReadString(sEntityName, iSize);
	}

	public void WriteEntityName() {
		this.WriteString(g_sHostname);
	}

	public void Dispatch()
	{
		char sDump[MAX_BUFFER_LENGTH];

		int iLen = this.Dump(sDump, MAX_BUFFER_LENGTH);

		this.Close();

		if (!SocketIsConnected(g_hSocket))
			return;

		// Len required
		// If len is not included, it will stop at the first \0 terminator
		SocketSend(g_hSocket, sDump, iLen);
	}
}

/**
 * Should only sent by clients
 * 
 * @field Token - string - The authentication token
 */
methodmap AuthenticateMessage < BaseMessage
{
	public int GetToken(char[] sToken, int iSize)
	{
		this.DataCursor();

		return this.ReadString(sToken, iSize);
	}

	public AuthenticateMessage(const char[] sToken)
	{
		BaseMessage m = BaseMessage();

		m.WriteByte(view_as<int>(MessageAuthenticate));
		m.WriteEntityName();

		m.WriteString(sToken);

		return view_as<AuthenticateMessage>(m);
	}
}

/**
 * This message is only received from the server
 * 
 * @field Response - byte - The state of the authentication request (enum AuthenticateResponse)
 */
methodmap AuthenticateMessageResponse < BaseMessage
{
	property AuthenticateResponse Response
	{
		public get()
		{
			this.DataCursor();

			AuthenticateResponse tByte = view_as<AuthenticateResponse>(this.ReadByte());

			return tByte >= AuthenticateResponseCount ? AuthenticateInvalid : tByte;
		}
	}
}

/**
 * Bi-directional messaging structure
 * 
 * @field IDType - byte - Type of ID (enum IdentificationType)
 * @field ID - string - The unique identification of the user (SteamID/Discord Snowflake/etc)
 * @field Username - string - The name of the user
 * @field Message - string - The message
 */
methodmap ChatMessage < BaseMessage
{
	property IdentificationType IDType
	{
		public get()
		{
			this.DataCursor();

			IdentificationType tByte = view_as<IdentificationType>(this.ReadByte());

			return tByte >= IdentificationTypeCount ? IdentificationInvalid : tByte;
		}
	}

	public int GetUserID(char[] sID, int iSize)
	{
		this.DataCursor();

		// Skip ID type
		this.Cursor++;

		return this.ReadString(sID, iSize);
	}

	public int GetUsername(char[] sUsername, int iSize)
	{
		this.DataCursor();

		// Skip ID type
		this.Cursor++;

		// Skip UserID
		this.ReadDiscardString();

		return this.ReadString(sUsername, iSize);
	}

	public int GetMessage(char[] sMessage, int iSize)
	{
		this.DataCursor();

		// Skip ID type
		this.Cursor++;

		// Skip UserID
		this.ReadDiscardString();

		// Skip Name
		this.ReadDiscardString();

		return this.ReadString(sMessage, iSize);
	}

	public ChatMessage(
		IdentificationType IDType,
		const char[] sUserID,
		const char[] sUsername,
		const char[] sMessage)
	{
		BaseMessage m = BaseMessage();

		m.WriteByte(view_as<int>(MessageChat));
		m.WriteEntityName();

		m.WriteByte(view_as<int>(IDType));
		m.WriteString(sUserID);
		m.WriteString(sUsername);
		m.WriteString(sMessage);

		return view_as<ChatMessage>(m);
	}
}

/**
 * Bi-directional event data
 * 
 * @field Event - string - The name of the event
 * @field Data - string - The data of the event
 */
methodmap EventMessage < BaseMessage
{
	public int GetEvent(char[] sEvent, int iSize)
	{
		this.DataCursor();

		return this.ReadString(sEvent, iSize);
	}

	public int GetData(char[] sData, int iSize)
	{
		this.DataCursor();

		// Skip event string
		this.ReadDiscardString();

		return this.ReadString(sData, iSize);
	}

	public EventMessage(const char[] sEvent, const char[] sData)
	{
		BaseMessage m = BaseMessage();

		m.WriteByte(view_as<int>(MessageEvent));
		m.WriteEntityName();

		m.WriteString(sEvent);
		m.WriteString(sData);

		return view_as<EventMessage>(m);
	}
}

public Plugin myinfo = 
{
	name = "Source Chat Relay",
	author = "Fishy, maxime1907, .Rushaway, Koen",
	description = "Communicate between Discord & In-Game, monitor server without being in-game, control the flow of messages and user base engagement!",
	version = "2.3.1",
	url = "https://keybase.io/RumbleFrog"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("Source-Chat-Relay");

	CreateNative("SCR_SendMessage", Native_SendMessage);
	CreateNative("SCR_SendEvent", Native_SendEvent);

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cHost = CreateConVar("rf_scr_host", "127.0.0.1", "Relay Server Host", FCVAR_PROTECTED);

	g_cPort = CreateConVar("rf_scr_port", "57452", "Relay Server Port", FCVAR_PROTECTED);
	
	g_cPrefix = CreateConVar("rf_scr_prefix", "", "Prefix required to send message to Discord. If empty, none is required.", FCVAR_NONE);
	
	g_cFlag = CreateConVar("rf_scr_flag", "", "If prefix is enabled, this admin flag is required to send message using the prefix", FCVAR_PROTECTED);

	g_cHostname = CreateConVar("rf_scr_hostname", "", "The hostname/displayname to send with messages. If left empty, it will use the server's hostname", FCVAR_NONE);

	g_cTimeStamp = CreateConVar("rf_scr_timestamp", "1", "Enable timestamp on messages", FCVAR_NONE, true, 0.0, true, 1.0);

	g_cAuthIdType = CreateConVar("rf_scr_authid_type", "2", "AuthID type used for display [0 = Engine, 1 = Steam2, 2 = Steam3, 3 = Steam64]", FCVAR_NONE, true, 0.0, true, 3.0);

	g_cDebug = CreateConVar("rf_scr_debug", "0", "Enable debug mode", FCVAR_NONE, true, 0.0, true, 1.0);

	// Start basic event convars
	g_cPlayerEvent = CreateConVar("rf_scr_event_player", "0", "Enable player connect/disconnect events", FCVAR_NONE, true, 0.0, true, 1.0);
	
	g_cBotPlayerEvent = CreateConVar("rf_scr_event_botplayer", "0", "Enable bot player connect/disconnect events", FCVAR_NONE, true, 0.0, true, 1.0);

	g_cMapEvent = CreateConVar("rf_scr_event_map", "0", "Enable map start/end events", FCVAR_NONE, true, 0.0, true, 1.0);

	RegAdminCmd("sm_reloadscr", Command_ReloadSCR, ADMFLAG_BAN, "Reload the plugin to try debug SCR");

	AutoExecConfig(true, "Source-Server-Relay");
	
	g_hSocket = SocketCreate(SOCKET_TCP, OnSocketError);

	SocketSetOption(g_hSocket, SocketReuseAddr, 1);
	SocketSetOption(g_hSocket, SocketKeepAlive, 1);
	
	if (g_cDebug.BoolValue)
		SocketSetOption(g_hSocket, DebugMode, 1);

	// ClientIndex, ClientName, Message
	g_hMessageSendForward = CreateGlobalForward(
		"SCR_OnMessageSend",
		ET_Event,
		Param_Cell,
		Param_String,
		Param_String);

	// EntityName, IDType, ID, ClientName, Message
	g_hMessageReceiveForward = CreateGlobalForward(
		"SCR_OnMessageReceive",
		ET_Event,
		Param_String,
		Param_Cell,
		Param_String,
		Param_String,
		Param_String);

	// sEvent, sData
	g_hEventSendForward = CreateGlobalForward(
		"SCR_OnEventSend",
		ET_Event,
		Param_String,
		Param_String);

	// sEvent, sData
	g_hEventReceiveForward = CreateGlobalForward(
		"SCR_OnEventReceive",
		ET_Event,
		Param_String,
		Param_String);

	g_evEngine = GetEngineVersion();

	// hook real player connects and disconnects
	HookEvent("player_connect", ePlayerJoinLeave);
	HookEvent("player_disconnect", ePlayerJoinLeave);
}

public void OnConfigsExecuted()
{
	g_cHostname.GetString(g_sHostname, sizeof g_sHostname);

	if (strlen(g_sHostname) == 0)
		GetConVarString(FindConVar("hostname"), g_sHostname, sizeof g_sHostname);

	g_cHost.GetString(g_sHost, sizeof g_sHost);
	
	g_cPrefix.GetString(g_sPrefix, sizeof g_sPrefix);
	
	g_iPort = g_cPort.IntValue;
	
	char sFlag[8];
	
	g_cFlag.GetString(sFlag, sizeof sFlag);
	
	if (strlen(sFlag) != 0)
	{
		AdminFlag aFlag;
		
		g_bFlag = FindFlagByChar(sFlag[0], aFlag);
		
		g_iFlag = FlagToBit(aFlag);
	}
	
	File tFile;

	char sPath[PLATFORM_MAX_PATH], sIP[64];
	
	Server_GetIPString(sIP, sizeof sIP);
	
	BuildPath(Path_SM, sPath, sizeof sPath, "data/%s_%d.data", sIP, Server_GetPort());
	
	if (FileExists(sPath, false))
	{
		tFile = OpenFile(sPath, "r", false);
		
		tFile.ReadString(g_sToken, sizeof g_sToken, -1);
	} else
	{
		tFile = OpenFile(sPath, "w", false);
	
		GenerateRandomChars(g_sToken, sizeof g_sToken, 64);
	
		tFile.WriteString(g_sToken, true);
	}

	delete tFile;

	if (!SocketIsConnected(g_hSocket))
	{
		ConnectRelay();

		// Stop. The map start event will emit on authentication reply packet
		return;
	}
	
	// If socket is already connected, emit map start
	if (g_cMapEvent.BoolValue)
	{
		char sMap[64];

		GetCurrentMap(sMap, sizeof sMap);

		EventMessage("**Map Start**", sMap).Dispatch();
	}
}

void ConnectRelay()
{	
	if (!SocketIsConnected(g_hSocket))
		SocketConnect(g_hSocket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, g_sHost, g_iPort);
	else
		PrintToServer("Source Chat Relay: Socket is already connected?");
}

public Action Timer_Reconnect(Handle timer)
{
	ConnectRelay();

	return Plugin_Continue;
}

void StartReconnectTimer()
{
	if (SocketIsConnected(g_hSocket))
		SocketDisconnect(g_hSocket);
		
	CreateTimer(10.0, Timer_Reconnect);
}

public void OnSocketDisconnected(Handle socket, any arg)
{
	StartReconnectTimer();

	PrintToServer("Source Chat Relay: Socket disconnected");
}

public void OnSocketError(Handle socket, int errorType, int errorNum, any ary)
{
	StartReconnectTimer();

	if (!g_bSocketErrorLogged)
	{
		g_bSocketErrorLogged = true;
		LogError("Source Chat Relay socket error %i (errno %i)", errorType, errorNum);
	}
	else
	{
		PrintToServer("Source Chat Relay: Socket error %i (errno %i)", errorType, errorNum);
	}
}

public void OnSocketConnected(Handle socket, any arg)
{
	AuthenticateMessage(g_sToken).Dispatch();

	PrintToServer("Source Chat Relay: Socket Connected");
}

public void OnSocketReceive(Handle socket, const char[] receiveData, int dataSize, any arg)
{
	HandlePackets(receiveData, dataSize);
}

public void HandlePackets(const char[] sBuffer, int iSize)
{
	BaseMessage base = view_as<BaseMessage>(CreateByteBuffer(true, sBuffer, iSize));

	switch(base.Type)
	{
		case MessageChat:
		{
			ChatMessage m = view_as<ChatMessage>(base);

			Action aResult;

			char sEntity[64], sID[64], sName[MAX_NAME_LENGTH], sMessage[MAX_COMMAND_LENGTH];

			m.GetEntityName(sEntity, sizeof sEntity);
			m.GetUsername(sName, sizeof sName);
			m.GetMessage(sMessage, sizeof sMessage);

			// Strip anything beyond 3 bytes for character as chat can't render it
			StripCharsByBytes(sEntity, sizeof sEntity);
			StripCharsByBytes(sName, sizeof sName);
			StripCharsByBytes(sMessage, sizeof sMessage);

			Call_StartForward(g_hMessageReceiveForward);
			Call_PushString(sEntity);
			Call_PushCell(m.IDType);
			Call_PushString(sID);
			Call_PushStringEx(sName, sizeof sName, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
			Call_PushStringEx(sMessage, sizeof sMessage, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
			Call_Finish(aResult);

			if (aResult >= Plugin_Handled)
			{
				base.Close();
				return;
			}

			if (g_cDebug.BoolValue)
			{
				PrintToConsoleAll("====== Chat Message Packet =====");
				PrintToConsoleAll("sEntity: %s", sEntity);
				PrintToConsoleAll("sName: %s", sName);
				PrintToConsoleAll("sMessage: %s", sMessage);
				PrintToConsoleAll("====== Chat Message Packet =====");
			}

			if (SupportsHexColor(g_evEngine))
				CPrintToChatAll("{gold}[%s] {azure}%s{white}: {grey}%s", sEntity, sName, sMessage);
			else
				CPrintToChatAll("\x10[%s] \x0C%s\x01: \x08%s", sEntity, sName, sMessage);
		}
		case MessageEvent:
		{
			EventMessage m = view_as<EventMessage>(base);

			Action aResult;

			char sEvent[MAX_EVENT_NAME_LENGTH], sData[MAX_COMMAND_LENGTH];

			m.GetEvent(sEvent, sizeof sEvent);
			m.GetData(sData, sizeof sData);

			// Strip anything beyond 3 bytes for character as chat can't render it
			StripCharsByBytes(sEvent, sizeof sEvent);
			StripCharsByBytes(sData, sizeof sData);

			Call_StartForward(g_hEventReceiveForward);
			Call_PushStringEx(sEvent, sizeof sEvent, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
			Call_PushStringEx(sData, sizeof sData, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
			Call_Finish(aResult);

			if (aResult >= Plugin_Handled)
			{
				base.Close();
				return;
			}
			
			if (SupportsHexColor(g_evEngine))
				CPrintToChatAll("{gold}[%s]{white}: {grey}%s", sEvent, sData);
			else
				CPrintToChatAll("\x10[%s]\x01: \x08%s", sEvent, sData);
		}
		case MessageAuthenticateResponse:
		{
			AuthenticateMessageResponse m = view_as<AuthenticateMessageResponse>(base);

			if (m.Response == AuthenticateDenied)
				SetFailState("Server denied our token. Stopping.");

			PrintToServer("Source Chat Relay: Successfully authenticated");

			// If socket wasn't connected prior, do time check see if we are close to map start
			if (GetGameTime() <= 20.0 && g_cMapEvent.BoolValue)
			{
				char sMap[64];

				GetCurrentMap(sMap, sizeof sMap);

				EventMessage("**Map Start**", sMap).Dispatch();
			}
		}
		default:
		{
			// They crazy
		}
	}

	base.Close();
}

// player connect/disconnect events
public void ePlayerJoinLeave(Handle event, const char[] name, bool dontBroadcast)
{
	bool connect;

	int userid = GetEventInt(event, "userid");
	int iClient = GetClientOfUserId(userid);
	bool bot = view_as<bool>(GetEventInt(event, "bot"));

	// If the userid is 0 that means they're connecting and we need to get their player slot instead
	if (!iClient)
	{
		int slot = GetEventInt(event, "index");
		iClient = slot+1;
		connect = true;
	}

	if (!Client_IsValid(iClient, false))
	{
		return;
	}

	if (!g_cPlayerEvent.BoolValue)
		return;

	if (!g_cBotPlayerEvent.BoolValue && bot)
		return;

	char sName[MAX_NAME_LENGTH];
	GetEventString(event, "name", sName, sizeof(sName), "");

	if (name[0] == '\0')
	{
		if (g_cDebug.BoolValue)
			PrintToServer("Client %N has no name (?)", iClient);
		return;
	}

	if (connect)
	{
		EventMessage("*Player Connected*", sName).Dispatch();
	}
	else
	{
		EventMessage("*Player Disconnected*", sName).Dispatch();
	}
}

public void OnMapStart()
{
	g_bSocketErrorLogged = false;
}

public void OnMapEnd()
{
	if (!g_cMapEvent.BoolValue)
		return;

	char sMap[64];

	GetCurrentMap(sMap, sizeof sMap);

	EventMessage("**Map Ended**", sMap).Dispatch();
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if (!Client_IsValid(client))
		return;
		
	if (!SocketIsConnected(g_hSocket))
		return;
		
	if (StrEqual(g_sPrefix, ""))
		DispatchMessage(client, sArgs);
	else
	{
		if (g_bFlag && !CheckCommandAccess(client, "arandomcommandthatsnotregistered", g_iFlag, true))
			return;

		if (StrContains(sArgs, g_sPrefix) != 0)
			return;
		
		char sBuffer[MAX_COMMAND_LENGTH];
		
		for (int i = strlen(g_sPrefix); i < strlen(sArgs); i++)
			Format(sBuffer, sizeof sBuffer, "%s%c", sBuffer, sArgs[i]);
		
		DispatchMessage(client, sBuffer);
	}
}

void DispatchMessage(int iClient, const char[] sMessage)
{
	char sID[64], sDisplayID[64], sName[MAX_NAME_LENGTH], tMessage[MAX_COMMAND_LENGTH], sFinalMessage[MAX_COMMAND_LENGTH];

	Action aResult;

	strcopy(tMessage, sizeof(tMessage), sMessage);
	StripQuotes(tMessage);

	// If the message is a command or empty, don't send it
	if (tMessage[0] == '/' || tMessage[0] == '@' || strlen(tMessage) == 0 || IsChatTrigger())
		return;

	AuthIdType authType = view_as<AuthIdType>(g_cAuthIdType.IntValue);
	if (!GetClientAuthId(iClient, AuthId_SteamID64, sID, sizeof sID))
	{
		return;
	}

	// Get the display ID based on the selected auth type
	if (authType == AuthId_SteamID64)
	{
		strcopy(sDisplayID, sizeof(sDisplayID), sID);
	}
	else if (!GetClientAuthId(iClient, authType, sDisplayID, sizeof sDisplayID))
	{
		return;
	}

	if (!GetClientName(iClient, sName, sizeof sName))
	{
		return;
	}

	// Block certain characters that leads to un-excepted formatting on Discord
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "`", "\\`");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "~", "\\~");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), ">", "\\>");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "<", "\\<");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "_", "\\_");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "*", "\\*");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "|", "\\|");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "/", "୵"); // Prevent URLs from being embedded
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), ".", "¸");
	ReplaceString(sFinalMessage, sizeof(sFinalMessage), "@", "ⓐ"); // Because it is a webhook, it bypasses the permission

	char sNameFormatted[MAX_NAME_LENGTH];
	FormatEx(sNameFormatted, sizeof(sNameFormatted), "%s | %s", sDisplayID, sName);

	// Format the final message to include timestamp before the name
	// Note: We open the code block before the timestamp/name and close it after the message to only have one code block
	char sFinalFormat[MAX_NAME_LENGTH];
	if (g_cTimeStamp.BoolValue)
		FormatEx(sFinalFormat, sizeof(sFinalFormat), "<t:%d:T> | `%s", GetTime(), sNameFormatted);
	else
		FormatEx(sFinalFormat, sizeof(sFinalFormat), "`%s", sNameFormatted);

	// Format message to prevent mardown formatting on Discord
	FormatEx(sFinalMessage, sizeof(sFinalMessage), "%s`", tMessage);

	if (g_cDebug.BoolValue)
	{
		PrintToConsoleAll("====== DispatchMessage =====");
		PrintToConsoleAll("sID: %s", sID);
		PrintToConsoleAll("sDisplayID: %s", sDisplayID);
		PrintToConsoleAll("sName: %s", sName);
		PrintToConsoleAll("sNameFormatted: %s", sNameFormatted);
		PrintToConsoleAll("sMessage: %s", sMessage);
		PrintToConsoleAll("sFinalMessage: %s", sFinalMessage);
		PrintToConsoleAll("====== DispatchMessage =====");
	}

	Call_StartForward(g_hMessageSendForward);
	Call_PushCell(iClient);
	Call_PushStringEx(sFinalFormat, sizeof(sFinalFormat), SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushStringEx(sFinalMessage, sizeof(sFinalMessage), SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_Finish(aResult);

	if (aResult >= Plugin_Handled)
		return;

	ChatMessage(IdentificationSteam, sID, sFinalFormat, sFinalMessage).Dispatch();
}

public int Native_SendMessage(Handle plugin, int numParams)
{
	if (numParams < 2)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Insufficient parameters");
	}

	char sBuffer[512];

	int iClient = GetNativeCell(1);

	FormatNativeString(0, 2, 3, sizeof sBuffer, _, sBuffer);

	DispatchMessage(iClient, sBuffer);

	return 0;
}

public int Native_SendEvent(Handle plugin, int numParams)
{
	if (numParams < 2)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Insufficient parameters");
	}

	Action aResult;

	char sEvent[MAX_EVENT_NAME_LENGTH], sData[MAX_COMMAND_LENGTH];

	GetNativeString(1, sEvent, sizeof sEvent);

	FormatNativeString(0, 2, 3, sizeof sData, _, sData);

	Call_StartForward(g_hEventSendForward);
	Call_PushStringEx(sEvent, sizeof sEvent, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushStringEx(sData, sizeof sData, SM_PARAM_STRING_UTF8 | SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_Finish(aResult);

	if (aResult >= Plugin_Handled)
		return 0;

	EventMessage(sEvent, sData).Dispatch();

	return 0;
}

void GenerateRandomChars(char[] buffer, int buffersize, int len)
{
	char charset[] = "adefghijstuv6789!@#$%^klmwxyz01bc2345nopqr&+=";
	
	for (int i = 0; i < len; i++)
		Format(buffer, buffersize, "%s%c", buffer, charset[GetRandomInt(0, sizeof charset - 1)]);
}

void StripCharsByBytes(char[] sBuffer, int iSize, int iMaxBytes = 3)
{
	int iBytes;

	char[] sClone = new char[iSize];

	int i = 0;
	int j = 0;
	int iBSize = 0;

	while (i < iSize)
	{
		iBytes = IsCharMB(sBuffer[i]);

		if (iBytes == 0)
			iBSize = 1;
		else
			iBSize = iBytes;

		if (iBytes <= iMaxBytes)
		{
			for (int k = 0; k < iBSize; k++)
			{
				sClone[j] = sBuffer[i + k];

				j++;
			}
		}

		i += iBSize;
	}

	Format(sBuffer, iSize, "%s", sClone);
}

static int localIPRanges[] =
{
	10	<< 24,				// 10.
	127	<< 24 | 1,			// 127.0.0.1
	127	<< 24 | 16	<< 16,	// 127.16.
	192	<< 24 | 168	<< 16,	// 192.168.
};

int Server_GetIP(bool public_=true)
{
	int ip = 0;

	static ConVar cvHostip;

	if (cvHostip == null) {
		cvHostip = FindConVar("hostip");
		MarkNativeAsOptional("Steam_GetPublicIP");
	}

	if (cvHostip != null) {
		ip = cvHostip.IntValue;
	}

	if (ip != 0 && IsIPLocal(ip) == public_) {
		ip = 0;
	}

#if defined _steamtools_included
	if (ip == 0) {
		if (CanTestFeatures() && GetFeatureStatus(FeatureType_Native, "Steam_GetPublicIP") == FeatureStatus_Available) {
			int octets[4];
			Steam_GetPublicIP(octets);

			ip =
				octets[0] << 24	|
				octets[1] << 16	|
				octets[2] << 8	|
				octets[3];

			if (IsIPLocal(ip) == public_) {
				ip = 0;
			}
		}
	}
#endif

	return ip;
}

bool Server_GetIPString(char[] buffer, int size, bool public_=true)
{
	int ip;

	if ((ip = Server_GetIP(public_)) == 0) {
		buffer[0] = '\0';
		return false;
	}

	LongToIP(ip, buffer, size);

	return true;
}

int Server_GetPort()
{
	static ConVar cvHostport;

	if (cvHostport == null) {
		cvHostport = FindConVar("hostport");
	}

	if (cvHostport == null) {
		return 0;
	}

	int port = cvHostport.IntValue;

	return port;
}

bool IsIPLocal(int ip)
{
	int range, bits, move;
	bool matches;

	for (int i=0; i < sizeof(localIPRanges); i++) {

		range = localIPRanges[i];
		matches = true;

		for (int j=0; j < 4; j++) {
			move = j * 8;
			bits = (range >> move) & 0xFF;

			if (bits && bits != ((ip >> move) & 0xFF)) {
				matches = false;
			}
		}

		if (matches) {
			return true;
		}
	}

	return false;
}

void LongToIP(int ip, char[] buffer, int size)
{
	Format(
		buffer, size,
		"%d.%d.%d.%d",
			(ip >> 24)	& 0xFF,
			(ip >> 16)	& 0xFF,
			(ip >> 8 )	& 0xFF,
			ip        	& 0xFF
		);
}

bool Client_IsValid(int client, bool checkConnected=true)
{
	if (client > 4096) {
		client = EntRefToEntIndex(client);
	}

	if (client < 1 || client > MaxClients) {
		return false;
	}

	if (checkConnected && !IsClientConnected(client)) {
		return false;
	}

	return true;
}

bool SupportsHexColor(EngineVersion e)
{
	switch (e)
	{
		case Engine_CSS, Engine_HL2DM, Engine_DODS, Engine_TF2, Engine_Insurgency, Engine_Unknown:
			return true;
		default:
			return false;
	}
}

public Action Command_ReloadSCR(int client, int args)
{
	char sFilename[256];
	GetPluginFilename(INVALID_HANDLE, sFilename, sizeof(sFilename));
	ServerCommand("sm plugins reload %s", sFilename);
	ReplyToCommand(client, "[SCR] Please wait.. Plugin is reloading..");
	LogAction(-1, -1, "\"%L\" reloaded SourceChatRelay Plugin", client);
	return Plugin_Handled;
}

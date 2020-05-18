module pastemyst.web.paste;

import vibe.d;
import vibe.web.auth;
import pastemyst.data;
import pastemyst.web;

import std.typecons : Nullable;

/++
 + web interface for getting pastes
 +/
@requiresAuth
public class PasteWeb
{
    mixin Auth;

    /++
     + GET /:id
     +
     + gets the paste with the specified id
     +/
    @path("/:id")
    @noAuth
    public void getPaste(string _id, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById;
		import std.conv : to;
 
		const auto res = findOneById!Paste(_id);
 
		if (res.isNull)
		{
			return;
		}
 
		const Paste paste = res.get();
 
        UserSession session = UserSession.init;

        if (req.session && req.session.isKeySet("user"))
        {
            session = req.session.get!UserSession("user");    
        }

		render!("paste.dt", paste, session);
    }

    /++
     + POST /:id/togglePublicOnProfile
     +
     + toggles whether the post is public on the user's profile
     +/
    @path("/:id/togglePublicOnProfile")
    @noAuth
    public void postTogglePublicOnProfile(string _id, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById, update;

        const auto res = findOneById!Paste(_id);

        if (res.isNull)
        {
            return;
        }

        const Paste paste = res.get();

        UserSession session = UserSession.init;

        if (req.session && req.session.isKeySet("user"))
        {
            session = req.session.get!UserSession("user");

            if (paste.ownerId != "" && paste.ownerId == session.user.id)
            {
                update!Paste(["_id": _id], ["$set": ["isPublic": !paste.isPublic]]);
                redirect("/" ~ _id);
                return;
            }
        }

        throw new HTTPStatusException(HTTPStatus.forbidden);
    }

    /++
     + POST /:id/delete
     +
     + deletes a user's paste
     +/
    @path("/:id/delete")
    @noAuth
    public void postPasteDelete(string _id, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById, removeOneById;

        const auto res = findOneById!Paste(_id);

        if (res.isNull)
        {
            return;
        }

        const Paste paste = res.get();

        UserSession session = UserSession.init;

        if (req.session && req.session.isKeySet("user"))
        {
            session = req.session.get!UserSession("user");

            if (paste.ownerId != "" && paste.ownerId == session.user.id)
            {
                removeOneById!Paste(_id);
                redirect("/user/profile");
                return;
            }
        }

        throw new HTTPStatusException(HTTPStatus.forbidden);
    }

    /++
     + POST /paste
     +
     + creates a paste
     +/
    @noAuth
    public void postPaste(string title, string expiresIn, bool isPrivate, bool isPublic, string pasties,
            HTTPServerRequest req)
    {
        import pastemyst.paste : createPaste;
        import pastemyst.db : insert;

        // TODO: private pastes

        string ownerId = "";

        UserSession session = UserSession.init;

        if (req.session && req.session.isKeySet("user"))
        {
            session = req.session.get!UserSession("user");

            if (session.loggedIn)
            {
                ownerId = session.user.id;
            }
        }

        Paste paste = createPaste(title, expiresIn, deserializeJson!(Pasty[])(pasties), isPrivate, ownerId);

        if (isPublic)
        {
            if (session.loggedIn)
            {
                paste.isPublic = isPublic;
            }
            else
            {
                throw new HTTPStatusException(HTTPStatus.forbidden,
                        "you cant create a profile public paste if you are not logged in.");
            }
        }

        insert(paste);

        redirect("/" ~ paste.id);
    }

    /++
     + GET /raw/:id/index
     +
     + gets the raw data of the pasty
     +/
	@path("/raw/:id/:index")
    @noAuth
	public void getRawPasty(string _id, int _index)
	{
		import pastemyst.db : findOneById;
		import pastemyst.data : Paste;
		
		const auto paste = findOneById!Paste(_id);
		enforceHTTP(!paste.isNull, HTTPStatus.notFound, "invalid paste id.");
		enforceHTTP(!(_index + 1 > paste.get().pasties.length || _index < 0), HTTPStatus.notFound, "invalid pasty index.");

		const auto pasty = paste.get().pasties[_index];
		const string pasteTitle = paste.get().title == "" ? "untitled" : paste.get().title;
		const string pastyTitle = pasty.title == "" ? "untitled" : pasty.title;
		const string title = pasteTitle ~ " - " ~ pastyTitle;
		const string rawCode = pasty.code;

		render!("raw.dt", title, rawCode);
    }

    /++
     + GET /:id/edit
     +
     + page for editing the paste
     +/
    @path("/:id/edit")
    @anyAuth
    public void getPasteEdit(string _id, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById;

        UserSession session = req.session.get!UserSession("user");
        auto res = findOneById!Paste(_id);

        if (res.isNull())
        {
            return;
        }

        const paste = res.get();

        render!("editPaste.dt", session, paste);
    }

    /++
     + POST /:id/edit
     +
     + edit a paste
     +/
    @path("/:id/edit")
    @method(HTTPMethod.POST)
    @anyAuth
    public void postPasteEdit(string _id, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById, update;
        import std.array : split;
        import std.conv : to;
        import std.datetime : Clock;
        import pastemyst.util : generateDiff;
        import std.algorithm : canFind, find, countUntil, remove;

        auto res = findOneById!Paste(_id);

        if (res.isNull())
        {
            return;
        }

        Paste paste = res.get();

        Paste editedPaste;
        editedPaste.title = req.form["title"];
        
        int i = 0;
        while(true)
        {
            Pasty pasty;
            if (("title-" ~ i.to!string()) !in req.form)
            {
                break;
            }

            pasty.id = req.form["id-" ~ i.to!string()];
            pasty.title = req.form["title-" ~ i.to!string()];
            pasty.language = req.form["language-" ~ i.to!string()].split(",")[0];
            pasty.code = req.form["code-" ~ i.to!string()];
            editedPaste.pasties ~= pasty;

            i++;
        }

        ulong editId = 0;
        if (paste.edits.length > 0)
        {
            editId = paste.edits[$-1].editId + 1;
        }
        const editedAt = Clock.currTime().toUnixTime();

        if (paste.title != editedPaste.title)
        {
            Edit edit;
            edit.uniqueId = generateUniqueEditId(paste);
            edit.editId = editId;
            edit.editType = EditType.title;
            edit.edit = paste.title;
            edit.editedAt = editedAt;

            paste.title = editedPaste.title;
            paste.edits ~= edit;
        }

        foreach (editedPasty; editedPaste.pasties)
        {
            if (paste.pasties.canFind!((p) => p.id == editedPasty.id))
            {
                ulong pastyIndex = paste.pasties.countUntil!((p) => p.id == editedPasty.id);
                Pasty pasty = paste.pasties[pastyIndex];

                if (pasty.title != editedPasty.title)
                {
                    Edit edit;
                    edit.uniqueId = generateUniqueEditId(paste);
                    edit.editId = editId;
                    edit.editType = EditType.pastyTitle;
                    edit.edit = pasty.title;
                    edit.metadata ~= pasty.id.to!string();
                    edit.editedAt = editedAt;

                    pasty.title = editedPasty.title;
                    paste.pasties[pastyIndex] = pasty;
                    paste.edits ~= edit;
                }

                if (pasty.language != editedPasty.language)
                {
                    Edit edit;
                    edit.uniqueId = generateUniqueEditId(paste);
                    edit.editId = editId;
                    edit.editType = EditType.pastyLanguage;
                    edit.edit = pasty.language;
                    edit.metadata ~= pasty.id.to!string();
                    edit.editedAt = editedAt;

                    pasty.language = editedPasty.language;
                    paste.pasties[pastyIndex] = pasty;
                    paste.edits ~= edit;
                }

                if (pasty.code != editedPasty.code)
                {
                    Edit edit;
                    edit.uniqueId = generateUniqueEditId(paste);
                    edit.editId = editId;
                    edit.editType = EditType.pastyContent;
                    edit.metadata ~= pasty.id.to!string();
                    edit.editedAt = editedAt;

                    string diffId = paste.id ~ "-" ~ edit.uniqueId;

                    edit.edit = generateDiff(diffId, pasty.code, editedPasty.code);

                    pasty.code = editedPasty.code;
                    paste.pasties[pastyIndex] = pasty;
                    paste.edits ~= edit;
                }
            }
        }

        foreach (pasty; paste.pasties)
        {
            if (!editedPaste.pasties.canFind!((p) => p.id == pasty.id))
            {
                Edit edit;
                edit.uniqueId = generateUniqueEditId(paste);
                edit.editId = editId;
                edit.editType = EditType.pastyRemoved;
                edit.edit = pasty.code;
                edit.metadata ~= pasty.title;
                edit.metadata ~= pasty.language;
                edit.editedAt = editedAt;

                paste.pasties = paste.pasties.remove!((p) => p.id == pasty.id);
                paste.edits ~= edit;
            }
        }

        foreach (editedPasty; editedPaste.pasties)
        {
            if (editedPasty.id == "")
            {
                Edit edit;
                edit.uniqueId = generateUniqueEditId(paste);
                edit.editId = editId;
                edit.editType = EditType.pastyAdded;
                edit.edit = editedPasty.code;
                edit.metadata ~= editedPasty.title;
                edit.metadata ~= editedPasty.language;
                edit.editedAt = editedAt;

                editedPasty.id = generateUniquePastyId(paste);
                paste.pasties ~= editedPasty;
                paste.edits ~= edit;
            }
        }

        update!Paste(["_id": _id], paste);

        redirect("/" ~ _id);
    }

    private string generateUniqueEditId(Paste paste)
    {
        import pastemyst.encoding : randomBase36Id;
        import std.algorithm : canFind;

        string id;

        do
        {
            id = randomBase36Id();
        } while(paste.edits.canFind!((e) => e.uniqueId == id));

        return id;
    }

    /++
     + GET /:id/history
     +
     + get all the edits of a paste
     +/
    @path("/:id/history")
    @noAuth
    public void getPasteHistory(string _id, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById;

        auto res = findOneById!Paste(_id);

        if (res.isNull())
        {
            return;
        }

        Paste paste = res.get();
        // TODO: this line is here because otherwise d-scanner
        // complains that paste isn't changed anywhere and it can be
        // declared const
        paste.title = paste.title;

        UserSession session = UserSession.init;

        if (req.session && req.session.isKeySet("user"))
        {
            session = req.session.get!UserSession("user");    
        }

        render!("history.dt", session, paste);
    }

    /++
     + GET /:pasteId/history/:editId
     +
     + gets the paste at the specific edit
     +/
    @path("/:pasteId/history/:editId")
    @noAuth
    public void getPasteRevision(string _pasteId, ulong _editId, HTTPServerRequest req)
    {
        import pastemyst.db : findOneById;
        import std.algorithm : reverse, countUntil;
        import std.stdio : writeln;

        auto res = findOneById!Paste(_pasteId);

        if (res.isNull)
        {
            return;
        } 

        Paste paste = res.get();

        foreach (edit; paste.edits.reverse())
        {
            final switch (edit.editType)
            {
                case EditType.title:
                {
                    paste.title = edit.edit;
                } break;

                case EditType.pastyTitle:
                {
                    ulong pastyIndex = paste.pasties.countUntil!((p) => p.id == edit.metadata[0]);
                    paste.pasties[pastyIndex].title = edit.edit;
                } break;

                case EditType.pastyLanguage:
                {

                    ulong pastyIndex = paste.pasties.countUntil!((p) => p.id == edit.metadata[0]);
                    paste.pasties[pastyIndex].language = edit.edit;
                } break;

                case EditType.pastyContent:
                {

                } break;

                case EditType.pastyAdded:
                {

                } break;

                case EditType.pastyRemoved:
                {

                } break;
            }

            if (edit.editId > _editId)
            {
                break;
            }
        }

        UserSession session = UserSession.init;

        if (req.session && req.session.isKeySet("user"))
        {
            session = req.session.get!UserSession("user");    
        }

        const bool previousRevision = true;
        const ulong currentEditId = _editId;
        render!("paste.dt", session, paste, previousRevision, currentEditId);
    }
}

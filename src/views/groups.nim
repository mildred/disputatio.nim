import std/prelude
import std/options

import templates

import ../db/groups
import ../db/articles
import ../convert_articles
import ./common
import ./articles as varticles

func group_new*(): string = tmpli html"""
  <article>
    New Identity
    <form method="POST" action="/@/">
      <input type="text" name="name" placeholder="name" />
      <input type="hidden" name="_preset" value="identity" />
      <input type="submit" value="Create"/>
    </form>
  </article>
  <article>
    New Empty Group
    <form method="POST" action="/@/">
      <input type="text" name="name" placeholder="name" />
      <input type="text" name="seed_userdata" placeholder="seed" />
      <input type="text" name="self_nickname" placeholder="our nickname" />
      <label>
        <input type="checkbox" name="empty_group" value="1" />
        Empty group
      </label>
      <select name="group_type">
        <option value="0">strict private group</option>
        <option value="1">unlisted private group</option>
        <option value="3">public group</option>
      </select>
      <select name="others_members_weight">
        <option value="0">Anyone can become a guest</option>
        <option value="1">Anyone can join (weight: 1)</option>
      </select>
      <select name="moderation_default_score">
        <option value="0">Guest posts are moderated by default (score: 0)</option>
        <option value="1">Guest posts are visible by default (score: 1)</option>
      </select>
      <input type="submit" value="Create"/>
    </form>
  </article>
"""

func group_list*(groups: seq[GroupItem]): string = tmpli html"""
  <p>Member of $(groups.len) groups</p>
  $if groups.len > 0 {
    <ul>
      $for group in groups {
        <li>
          <a href="/@$(group.guid)/">$(group.name)</a>
        </li>
      }
    </ul>
  }
  $(group_new())
"""

func group_members_show*(group: GroupItem): string = tmpli html"""
  $if group.group_type == 0 and group.members.len <= 1 {
    <p>
      Your nickname is <strong>$(group.members[0].nickname)</strong>($(group.members[0].local_id))
      $if group.members[0].weight != 1 {
        and your weight is $(group.members[0].weight)
      }
    </p>
  }
  $else {
    <p>$(group.members.len) member(s) in the group:</p>
    <ul>
      $for member in group.members {
        <li>
          $if member.weight < 0 {
            <del>$(member.nickname)</del>($(member.local_id))
          }
          $else {
            <strong>$(member.nickname)</strong>($(member.local_id))
            $if member.weight == 0 {
              <em>(guest)</em>
            }
            $elif member.weight != 1 {
              <em>(weight: $(member.weight))</em>
            }
          }
        </li>
      }
    </ul>
  }
"""

func message_from_self*(art: Article, group: GroupItem, member: Option[GroupMember]): bool =
  result =
    member.is_some and
    art.author_group_guid == group.guid and
    art.author_member_id == member.get.local_id

func group_show*(group: GroupItem, member: Option[GroupMember], posts: seq[Article]): string = tmpli html"""
  <p>
  $if group.group_type == 0 {
    $if group.members.len == 1 {
      <strong>This is one of your identities.</strong>
      The group is private and new members must be authorized by you. Posts to
      this group are only visible to you. Group existance is not private and can
      be used as a public identity.
    }
    $else {
      <strong>This is a private group, new members must be authorized</strong> by
      existing members. No other way to join the group is made possible.
      Posts are only propagated to the pods of the members and unknown pods cannot
      access the posts.
    }
  }
  $elif group.group_type == 1 {
    <strong>This is a private group accessible by invite link.</strong> Posts
    are only propagated to members.
  }
  $elif group.group_type == 3 {
    <strong>This is a public group</strong> and the invite link can be
    published. It may be globally searchable and posts can be propagated
    publicly to any pod even without members.
  }
  $else {
    <strong>This is an unknown group type</strong> and the pod is probably out
    of date.
  }

  $if group.group_type != 0 {
    $if group.others_members_weight == 0 and group.moderation_default_score == 0 {
      <strong>This is an announce group</strong> and only authorized members can
      post.
    }
    $elif group.others_members_weight == 0 {
      <strong>Group is moderated</strong>, anyone can become a guest but only
      authorized members can moderate the posts.
      $if group.moderation_default_score == 0 {
        Guest posts will not be visible by default.
      }
      $elif group.moderation_default_score == 1 {
        Guest posts are visible unless moderated.
      }
      $elif group.moderation_default_score > 0 {
        Guest posts will be visible and receive a default moderation score of
        $(group.moderation_default_score).
      }
      $else {
        Guest posts will not be visible by default because the default
        moderation score is of $(group.moderation_default_score).
      }
    }
    $elif group.others_members_weight == 1 {
      <strong>Group is free</strong>, anyone can become a full member.
      Moderation is collective by each member weight.
    }
    $else {
      <strong>Group is free</strong>, anyone can become a full member and
      receeive a weight of $(group.others_members_weight). Moderation is
      collective by each member weight.
    }
  }
  </p>

  $(group_members_show(group))

  <div class="group-message-list">
    ${ var last_local_id = -1; }
    $for art in posts {
      <article
        class="
          message
          $(if message_from_self(art, group, member): "message-self" else: "")
        "
        data-patch-id="$(h($art.patch_id))"
        class="viewer">
        $if last_local_id != art.group_member.local_id {
          <p class="message-author">$(h(art.group_member.nickname))</p>
        }
        $(art.to_html())
        <p class="message-score">$(h($art.score))</p>
        <p class="message-time">$(h(art.timestamp.format_time()))</p>
      </article>
      ${ last_local_id = art.group_member.local_id }
    }
  </div>

  $if member.is_some() {
    $(article_editor("", "", fullpage = false, url = "./posts/", save_btn = "Send"))
  }
  $elif group.others_members_weight != 0 or group.moderation_default_score != 0  {
    <form action="./join/" method="POST">
      <label>Nickname : <input type="text" name="self_nickname" /></label>
      <button>Join</button>
    </form>
  }
"""


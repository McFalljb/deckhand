*em* _em_ **strong** __strong__ ***both*** *nested **strong** em*
snake_case_word and intra*word*emphasis and __proper__ **_mixed_**
~single strike~ ~~double strike~~ ~~~triple~~~ ~~*em in strike*~~

`code` ``double ` tick`` ` spaced ` `multi
line code` ```unclosed

\*escaped\* \_not em\_ \`not code\` \# \[not link\] \\ backslash \a not escape

&amp; &lt; &gt; &quot; &copy; &nbsp;x &#35; &#x41; &#0; &#xD800; &madeup; &amp &Afr; &#1234567890;

Raw <span class="x">inline html</span> and <br> and <BR/> and <br/>break
and <a href="javascript:alert(1)">html link</a> and <!-- comment --> and
<img src="x" onerror="alert(1)"> and <?php echo ?> and <![CDATA[x]]>

[inline](https://example.com/a "Title") [no title](http://example.com)
[angle](<a b.md>) [parens](foo(bar)baz.md) [rel](docs/other.md#section)
[anchor](#heading) [empty]() [title only]("t") [single](/s 'single title')
[nested *em* `code`](https://example.com/n) [link [with] brackets](/b)
[with entity](https://example.com/?a=1&amp;b=2) [escaped](https://example.com/\_x)
[unicode](https://例え.jp/パス) [space%20encoded](my%20file.md)
![image alt *em*](soup.png "Image title") ![](empty-alt.png)
[![image in link](i.png)](https://example.com/img)
![img [nested](link.md) alt](x.png)

[unknown ref] [Shortcut] [collapsed][] [Full][shortcut]

[shortcut]: https://example.com/shortcut
[collapsed]: /collapsed

Autolinks: <https://example.com/auto> <mailto:me@example.invalid>
<me@example.invalid> <ftp://files.example.com> <irc://chat.example>
<made-up-scheme:thing> <not a link> <http://example.com/a b>

Bare: https://example.com/bare, www.example.org/path. http://example.com/x?y=1&z=2
(www.example.com/in-parens) trailing punctuation www.example.com/x. and
email someone@example.invalid and a.b-c_d@sub.example.invalid. ftp://ftp.example.com/f
https://example.com/foo_(bar) https://example.com/q?a=b#frag
not.a.link and http:// and www. alone and xmpp:me@example.invalid

Hard break at end with two spaces  
next line. Backslash at very end\

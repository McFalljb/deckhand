# Safety

[js](javascript:alert(1))
[js upper](JAVASCRIPT:alert(1))
[js mixed](JaVaScRiPt:alert(1))
[js entity](java&#115;cript:alert(1))
[js named entity](javascript&colon;alert(1))
[js escaped](javascript\:alert(1))
[js angle](<javascript:alert(1)>)
[js spaces]( javascript:alert(1) )
[js tab](java	script:alert(1))
[vbscript](vbscript:msgbox(1))
[data](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)
[data upper](DATA:text/html,<script>alert(1)</script>)
[file](file:///etc/passwd)
[app scheme](deckhand://do-something)
[percent scheme](%6Aavascript:alert(1))
[newline in dest](java
script:alert(1))
[ref js][jsref]
<javascript:alert(1)>
<data:text/html,x>
<file:///etc/passwd>
javascript:alert(1) as bare text
www.example.com/javascript:alert(1)

[jsref]: javascript:alert('ref')

![img js](javascript:alert(1))
![img data](data:image/png;base64,iVBORw0KGgo=)
![img remote](https://tracker.example.com/pixel.gif)
![img file](file:///etc/passwd)

<a href="javascript:alert(1)">raw link</a>
<img src=x onerror=alert(1)>
<iframe src="https://example.com"></iframe>
<script>alert(1)</script>
<style>body{display:none}</style>
<textarea>raw</textarea>

<div onclick="alert(1)">

*markdown inside an html block after a blank line*

</div>

<title>tag filter</title> <xmp>x</xmp> <noembed>y</noembed>

[mail](mailto:a@example.invalid?subject=hi)
[https](https://example.com/ok)
[http](http://example.com/ok)
[relative](other.md)
[absolute](/etc/hosts)
[dotdot](../../outside.md)
[anchor](#safety)
[query](other.md?x=1#frag)

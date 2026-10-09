<?php

namespace App\Apptest;

use Illuminate\Support\Facades\Mail;

/*
 * A mailer on the array transport, whichever way this framework generation
 * builds one: named mailers exist from 7 (Symfony transport from 9), before
 * that there is one mailer whose SwiftMailer is swapped.
 */
class Mailbox
{
    public static function deliver($to, $mailable)
    {
        if (method_exists(Mail::getFacadeRoot(), 'mailer')) {
            $mailer = Mail::mailer('array');
            $mailer->to($to)->send($mailable);
            if (method_exists($mailer, 'getSymfonyTransport')) {
                $sent = $mailer->getSymfonyTransport()->messages();

                return count($sent) ? [$sent->last()->getOriginalMessage()->getSubject()] : [];
            }
            $transport = $mailer->getSwiftMailer()->getTransport();
        } else {
            $mailer = clone app('mailer');
            $transport = new \Illuminate\Mail\Transport\ArrayTransport();
            $mailer->setSwiftMailer(new \Swift_Mailer($transport));
            $mailer->to($to)->send($mailable);
        }

        return $transport->messages()->map(function ($m) {
            return $m->getSubject();
        })->all();
    }
}
